defmodule SymphonyElixir.TerminalWorkspaceSweepTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Client

  test "periodic sweep claims candidates, revalidates, and removes only still-terminal workspaces" do
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
      reopened_workspace = Path.join(test_root, "MT-703")
      Enum.each([done_workspace, claimed_workspace, active_workspace, reopened_workspace], &File.mkdir_p!/1)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: "issue-700", identifier: "MT-700", state: "Done"},
        %Issue{id: "issue-701", identifier: "MT-701", state: "Canceled"},
        %Issue{id: "issue-702", identifier: "MT-702", state: "In Progress"},
        %Issue{id: "issue-703", identifier: "MT-703", state: "Done"}
      ])

      state = %Orchestrator.State{claimed: MapSet.new(["issue-701"])}

      # The test process stands in for the orchestrator: the sweep task calls
      # back into it to claim candidates.
      {:noreply, %Orchestrator.State{terminal_sweep_pid: sweep_pid} = state} =
        Orchestrator.handle_info(:terminal_workspace_sweep, state)

      assert is_pid(sweep_pid)
      sweep_ref = Process.monitor(sweep_pid)

      # A second tick while the sweep is in flight must not start another one.
      assert {:noreply, %Orchestrator.State{terminal_sweep_pid: ^sweep_pid}} =
               Orchestrator.handle_info(:terminal_workspace_sweep, state)

      assert_receive {:"$gen_call", from, {:claim_for_terminal_sweep, candidate_ids}}, 5_000
      assert Enum.sort(candidate_ids) == ["issue-700", "issue-701", "issue-703"]

      {:reply, granted, state} = Orchestrator.handle_call({:claim_for_terminal_sweep, candidate_ids}, from, state)

      # Already-claimed issues are not granted; granted ones are now claimed,
      # which keeps dispatch away from them while their workspace is removed.
      assert Enum.sort(granted) == ["issue-700", "issue-703"]
      assert MapSet.equal?(state.claimed, MapSet.new(["issue-700", "issue-701", "issue-703"]))

      # MT-703 is reopened after the sweep's first fetch: revalidation keeps it.
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %Issue{id: "issue-700", identifier: "MT-700", state: "Done"},
        %Issue{id: "issue-701", identifier: "MT-701", state: "Canceled"},
        %Issue{id: "issue-702", identifier: "MT-702", state: "In Progress"},
        %Issue{id: "issue-703", identifier: "MT-703", state: "Todo"}
      ])

      GenServer.reply(from, granted)
      assert_receive {:DOWN, ^sweep_ref, :process, ^sweep_pid, _reason}, 5_000

      refute File.exists?(done_workspace)
      assert File.exists?(claimed_workspace)
      assert File.exists?(active_workspace)
      assert File.exists?(reopened_workspace)

      # When the sweep task exits, its claims are released and the
      # pre-existing claim stays.
      assert {:noreply, %Orchestrator.State{terminal_sweep_pid: nil} = state} =
               Orchestrator.handle_info({:DOWN, sweep_ref, :process, sweep_pid, :normal}, state)

      assert MapSet.equal?(state.claimed, MapSet.new(["issue-701"]))
      assert MapSet.size(state.terminal_sweep_claims) == 0
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "claims from anything but the running sweep task are refused" do
    state = %Orchestrator.State{terminal_sweep_pid: spawn(fn -> :ok end)}

    assert {:reply, [], ^state} =
             Orchestrator.handle_call({:claim_for_terminal_sweep, ["issue-1"]}, {self(), make_ref()}, state)
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
