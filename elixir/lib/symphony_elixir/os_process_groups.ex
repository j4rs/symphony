defmodule SymphonyElixir.OsProcessGroups do
  @moduledoc """
  Tracks the OS process groups each worker starts through ports (workspace hooks, codex), so
  they can be killed when Symphony abandons the worker.

  A killed Elixir process closes its ports, but the OS processes behind them keep running: a
  stalled or terminated run would otherwise leave its `after_create` prep or its codex alive,
  outside any control, while a retry starts in the same workspace. `erl_child_setup` starts
  every port in its own session, so the port's OS pid is the leader of a process group that
  holds everything it spawned.
  """

  use GenServer

  @table __MODULE__
  @term_grace_ms 2_000
  @poll_ms 100

  # The process exists only to own the ETS table for the application's lifetime.
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :bag])
    {:ok, nil}
  end

  @doc "Records `os_pid` as a process group started by the calling process."
  @spec register(non_neg_integer()) :: :ok
  def register(os_pid) when is_integer(os_pid) do
    :ets.insert(@table, {self(), os_pid})
    :ok
  end

  @doc "Forgets `os_pid` for the calling process (its port finished normally)."
  @spec unregister(non_neg_integer()) :: :ok
  def unregister(os_pid) when is_integer(os_pid) do
    :ets.match_delete(@table, {self(), os_pid})
    :ok
  end

  @doc "Kills every process group registered by `owner` (a worker pid) and forgets them."
  @spec kill_owned_by(pid()) :: :ok
  def kill_owned_by(owner) when is_pid(owner) do
    for {^owner, os_pid} <- :ets.lookup(@table, owner), do: terminate(os_pid)
    :ets.delete(@table, owner)
    :ok
  end

  @doc """
  Sends TERM to the process group led by `os_pid` (or to the process alone if it leads no
  group), then KILL to whatever is left after a short grace period.
  """
  @spec terminate(non_neg_integer()) :: :ok
  def terminate(os_pid) when is_integer(os_pid) do
    target = if signal("0", "-#{os_pid}"), do: "-#{os_pid}", else: "#{os_pid}"

    if signal("TERM", target) and !wait_for_exit(target, @term_grace_ms) do
      signal("KILL", target)
    end

    :ok
  end

  defp wait_for_exit(target, remaining_ms) when remaining_ms <= 0, do: !signal("0", target)

  defp wait_for_exit(target, remaining_ms) do
    if signal("0", target) do
      Process.sleep(@poll_ms)
      wait_for_exit(target, remaining_ms - @poll_ms)
    else
      true
    end
  end

  defp signal(signal, target) do
    {_output, status} = System.cmd("kill", ["-s", signal, "--", target], stderr_to_stdout: true)
    status == 0
  end
end
