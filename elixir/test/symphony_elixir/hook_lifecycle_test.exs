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

  test "terminate also handles a process that leads no group, and one already gone" do
    # The shell prints the pid of a background child: in the shell's group, not a leader.
    port = Port.open({:spawn_executable, ~c"/bin/sh"}, [:binary, args: [~c"-c", ~c"sleep 60 & echo $!; wait"]])
    assert_receive {^port, {:data, data}}, 2_000
    child = data |> String.trim() |> String.to_integer()
    {:os_pid, leader} = :erlang.port_info(port, :os_pid)

    assert :ok = OsProcessGroups.terminate(child)
    {_out, status} = System.cmd("kill", ["-s", "0", "--", "#{child}"], stderr_to_stdout: true)
    assert status != 0
    OsProcessGroups.terminate(leader)

    # Nothing left to signal: a no-op.
    assert :ok = OsProcessGroups.terminate(child)
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

  test "the stall clock starts when the workspace is ready, not at dispatch" do
    now = DateTime.utc_now()
    long_ago = DateTime.add(now, -3_600, :second)

    # Still creating the workspace (after_create running): never stalled.
    assert Orchestrator.stall_elapsed_ms_for_test(%{started_at: long_ago}, now) == nil

    ready = DateTime.add(now, -10, :second)
    ready_entry = %{started_at: long_ago, workspace_ready_at: ready}
    assert Orchestrator.stall_elapsed_ms_for_test(ready_entry, now) in 9_000..11_000

    codex = DateTime.add(now, -2, :second)

    assert Orchestrator.stall_elapsed_ms_for_test(
             %{started_at: long_ago, workspace_ready_at: ready, last_codex_timestamp: codex},
             now
           ) in 1_000..3_000
  end
end
