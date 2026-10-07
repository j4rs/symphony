defmodule SymphonyElixir.HookLifecycleTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.OsProcessGroups

  defp group_alive?(pgid) do
    {_output, status} = System.cmd("kill", ["-s", "0", "--", "-#{pgid}"], stderr_to_stdout: true)
    status == 0
  end

  defp tmp_root(name) do
    Path.join(System.tmp_dir!(), "symphony-#{name}-#{System.unique_integer([:positive])}")
  end

  test "a killed worker's registered process groups are killed with it" do
    parent = self()

    worker =
      spawn(fn ->
        port =
          Port.open(
            {:spawn_executable, ~c"/bin/sh"},
            [:binary, args: [~c"-c", ~c"(trap '' TERM; sleep 60) & sleep 60; wait"]]
          )

        {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
        OsProcessGroups.register(os_pid)
        send(parent, {:started, os_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, os_pid}, 2_000
    Process.sleep(200)
    Process.exit(worker, :kill)
    Process.sleep(100)
    # Killing the Elixir process alone leaves the OS processes running...
    assert group_alive?(os_pid)

    # ...until the orchestrator kills what that worker registered.
    OsProcessGroups.kill_owned_by(worker)
    refute group_alive?(os_pid)
  end

  test "shutdown kills everything still registered; a process already gone isn't registered" do
    parent = self()

    owner =
      spawn(fn ->
        port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, args: [~c"-c", ~c"sleep 60"]])
        {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
        OsProcessGroups.register(os_pid)
        send(parent, {:started, os_pid})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, os_pid}, 2_000
    assert :ok = OsProcessGroups.terminate(:shutdown, nil)
    refute group_alive?(os_pid)
    Process.exit(owner, :kill)

    assert :ok = OsProcessGroups.register(2_147_483_000)
    assert :ets.match_object(OsProcessGroups, {self(), 2_147_483_000, :_}) == []
  end

  test "a group whose leader is no longer the registered process is never signalled" do
    port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, args: [~c"-c", ~c"sleep 60"]])
    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    owner = spawn(fn -> Process.sleep(:infinity) end)

    # As if the pid had been reused since registration: the recorded start time differs.
    :ets.insert(OsProcessGroups, {owner, os_pid, "not-its-start-time"})
    OsProcessGroups.kill_owned_by(owner)
    assert group_alive?(os_pid)

    assert :ok = OsProcessGroups.kill(os_pid)
    refute group_alive?(os_pid)
  end

  test "stop lets a group exit by itself before TERM; kill doesn't wait" do
    root = tmp_root("graceful-stop")
    File.mkdir_p!(root)
    termed = Path.join(root, "got-term")
    script = "trap 'touch #{termed}; exit 0' TERM; sleep 0.5"

    try do
      port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, args: [~c"-c", String.to_charlist(script)]])
      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
      OsProcessGroups.register(os_pid)
      assert :ok = OsProcessGroups.stop(os_pid)
      refute group_alive?(os_pid)
      refute File.exists?(termed)

      port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, args: [~c"-c", ~c"trap '' TERM; sleep 60"]])
      {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
      assert :ok = OsProcessGroups.kill(os_pid)
      refute group_alive?(os_pid)
    after
      File.rm_rf(root)
    end
  end

  test "a timed-out after_create is killed as a group and its workspace discarded" do
    root = tmp_root("hook-timeout")
    marker = Path.join(root, "still-running")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        hook_after_create: "(sleep 3; touch #{marker}) & sleep 30",
        hook_timeout_ms: 500
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 500}} = Workspace.create_for_issue("MT-900")
      refute File.exists?(Path.join(root, "MT-900"))
      refute File.exists?(Path.join([root, ".symphony-created", "MT-900"]))

      # The backgrounded child was part of the hook's group and died with it.
      Process.sleep(3_500)
      refute File.exists?(marker)
    after
      File.rm_rf(root)
    end
  end

  test "a workspace is reused only after after_create completed; otherwise it is rebuilt" do
    root = tmp_root("created-marker")
    counter = Path.join(root, "after-create-runs")

    try do
      File.mkdir_p!(root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        hook_after_create: "echo run >> #{counter}"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-901")
      assert File.exists?(Path.join([root, ".symphony-created", "MT-901"]))
      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-901")
      assert length(File.read!(counter) |> String.split("\n", trim: true)) == 1

      # A directory without the marker (Symphony stopped mid-prep) is rebuilt, not reused.
      File.rm!(Path.join([root, ".symphony-created", "MT-901"]))
      File.write!(Path.join(workspace, "half-built"), "")
      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-901")
      refute File.exists?(Path.join(workspace, "half-built"))
      assert length(File.read!(counter) |> String.split("\n", trim: true)) == 2

      # Removing the workspace forgets it too.
      Workspace.remove(workspace)
      refute File.exists?(Path.join([root, ".symphony-created", "MT-901"]))
    after
      File.rm_rf(root)
    end
  end

  test "a failed after_create discards the workspace" do
    root = tmp_root("after-create-fails")

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_after_create: "exit 3")

      assert {:error, {:workspace_hook_failed, "after_create", 3, _}} = Workspace.create_for_issue("MT-902")
      refute File.exists?(Path.join(root, "MT-902"))
    after
      File.rm_rf(root)
    end
  end

  test "the stall clock starts when the workspace is ready; creation has hooks.timeout_ms of budget" do
    write_workflow_file!(Workflow.workflow_file_path(), hook_timeout_ms: 60_000)
    now = DateTime.utc_now()

    # Still creating the workspace, within the hook budget: not stalled at all.
    assert Orchestrator.stall_elapsed_ms_for_test(%{started_at: DateTime.add(now, -30, :second)}, now) == 0

    # Creation running far past the hook budget does count.
    long_ago = DateTime.add(now, -3_600, :second)
    assert Orchestrator.stall_elapsed_ms_for_test(%{started_at: long_ago}, now) in 3_539_000..3_541_000

    ready = DateTime.add(now, -10, :second)
    ready_entry = %{started_at: long_ago, workspace_ready_at: ready}
    assert Orchestrator.stall_elapsed_ms_for_test(ready_entry, now) in 9_000..11_000

    codex = DateTime.add(now, -2, :second)

    assert Orchestrator.stall_elapsed_ms_for_test(
             %{started_at: long_ago, workspace_ready_at: ready, last_codex_timestamp: codex},
             now
           ) in 1_000..3_000
  end

  test "workspaces that predate markers are adopted once, not rebuilt" do
    root = tmp_root("adopt")
    counter = Path.join(root, "after-create-runs")

    try do
      File.mkdir_p!(Path.join(root, "MT-903"))
      File.write!(Path.join([root, "MT-903", "in-flight-work"]), "")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: root,
        hook_after_create: "echo run >> #{counter}"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-903")
      assert File.exists?(Path.join(workspace, "in-flight-work"))
      refute File.exists?(counter)
      assert File.exists?(Path.join([root, ".symphony-created", "MT-903"]))
    after
      File.rm_rf(root)
    end
  end

  test "a symlinked marker directory is refused, not written through" do
    root = tmp_root("marker-symlink")
    elsewhere = tmp_root("marker-target")

    try do
      File.mkdir_p!(root)
      File.mkdir_p!(elsewhere)
      File.ln_s!(elsewhere, Path.join(root, ".symphony-created"))
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root, hook_after_create: "true")

      assert {:error, _} = Workspace.create_for_issue("MT-904")
      assert File.ls!(elsewhere) == []
      refute File.exists?(Path.join(root, "MT-904"))
    after
      File.rm_rf(root)
      File.rm_rf(elsewhere)
    end
  end
end
