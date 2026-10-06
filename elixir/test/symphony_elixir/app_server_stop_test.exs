defmodule SymphonyElixir.AppServerStopTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.AppServer

  # Reproduces the GET-318/GET-319 orphan: a codex that never reads stdin
  # survives Port.close/1 and keeps its ~/.codex sqlite locks. stop_session/1
  # must take down the whole process group, including a child that ignores TERM.
  test "stop_session terminates the port's whole process group" do
    port =
      Port.open(
        {:spawn_executable, ~c"/bin/bash"},
        [:binary, :exit_status, args: [~c"-c", ~c"(trap '' TERM; sleep 60) & sleep 60; wait"]]
      )

    {:os_pid, os_pid} = :erlang.port_info(port, :os_pid)
    Process.sleep(200)
    assert group_alive?(os_pid)

    assert :ok = AppServer.stop_session(%{port: port})

    refute group_alive?(os_pid)
  end

  test "stop_session on an already-closed port is a no-op" do
    port = Port.open({:spawn_executable, ~c"/bin/true"}, [:binary, :exit_status])
    assert_receive {^port, {:exit_status, 0}}, 2_000

    assert :ok = AppServer.stop_session(%{port: port})
  end

  defp group_alive?(pgid) do
    {_output, status} = System.cmd("kill", ["-s", "0", "--", "-#{pgid}"], stderr_to_stdout: true)
    status == 0
  end
end
