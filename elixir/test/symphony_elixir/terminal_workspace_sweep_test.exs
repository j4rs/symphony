defmodule SymphonyElixir.TerminalWorkspaceSweepTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  test "periodic sweep removes terminal workspaces but skips claimed issues" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-sweep-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Canceled"]
      )

      done_workspace = Path.join(test_root, "MT-700")
      claimed_workspace = Path.join(test_root, "MT-701")
      active_workspace = Path.join(test_root, "MT-702")
      Enum.each([done_workspace, claimed_workspace, active_workspace], &File.mkdir_p!/1)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: "issue-700", identifier: "MT-700", state: "Done"},
        %Issue{id: "issue-701", identifier: "MT-701", state: "Canceled"},
        %Issue{id: "issue-702", identifier: "MT-702", state: "In Progress"}
      ])

      state = %Orchestrator.State{claimed: MapSet.new(["issue-701"])}

      {:noreply, %Orchestrator.State{terminal_sweep_pid: sweep_pid} = state} =
        Orchestrator.handle_info(:terminal_workspace_sweep, state)

      assert is_pid(sweep_pid)

      # A second tick while the sweep is in flight must not start another one.
      assert {:noreply, %Orchestrator.State{terminal_sweep_pid: ^sweep_pid}} =
               Orchestrator.handle_info(:terminal_workspace_sweep, state)

      ref = Process.monitor(sweep_pid)
      assert_receive {:DOWN, ^ref, :process, ^sweep_pid, _reason}, 5_000

      refute File.exists?(done_workspace)
      assert File.exists?(claimed_workspace)
      assert File.exists?(active_workspace)

      assert {:noreply, %Orchestrator.State{terminal_sweep_pid: nil}} =
               Orchestrator.handle_info({:DOWN, ref, :process, sweep_pid, :normal}, state)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "linear client proxy options follow HTTPS_PROXY" do
    assert Client.proxy_connect_options(%{}) == []
    assert Client.proxy_connect_options(%{"HTTPS_PROXY" => ""}) == []

    assert Client.proxy_connect_options(%{"HTTPS_PROXY" => "http://127.0.0.1:3128"}) ==
             [proxy: {:http, "127.0.0.1", 3128, []}]

    assert Client.proxy_connect_options(%{"https_proxy" => "http://proxy.local:8080/"}) ==
             [proxy: {:http, "proxy.local", 8080, []}]

    assert_raise ArgumentError, fn ->
      Client.proxy_connect_options(%{"HTTPS_PROXY" => "socks5://127.0.0.1:1080"})
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
