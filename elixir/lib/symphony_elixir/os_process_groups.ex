defmodule SymphonyElixir.OsProcessGroups do
  @moduledoc """
  Tracks the OS process groups each worker starts through ports (workspace hooks, codex), so
  they can be killed when Symphony abandons the worker.

  A killed Elixir process closes its ports, but the OS processes behind them keep running: a
  stalled or terminated run would otherwise leave its `after_create` prep or its codex alive,
  outside any control, while a retry starts in the same workspace. `erl_child_setup` starts
  every port in its own session, so the port's OS pid is the leader of a process group that
  holds everything it spawned (a process that calls `setsid` itself leaves the group; this is
  cleanup, not a containment boundary).

  Each registration records the leader's start time. A group is signalled only while its
  leader is that same process, or after the leader exited while the group still has members:
  Linux doesn't hand out a pid that is still a live group's id, so neither case can hit an
  unrelated process after pid reuse.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @exit_grace_ms 2_000
  @term_grace_ms 2_000
  # After KILL: until the kernel and erl_child_setup have reaped it (a zombie still answers
  # `kill -0`), so callers that go on to remove the workspace see the group gone.
  @kill_wait_ms 1_000
  @poll_ms 100

  # The process owns the ETS table for the application's lifetime and, on shutdown, kills
  # whatever is still registered.
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :bag])
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_owner, os_pid, started} -> {os_pid, started} end)
    |> signal_groups(0)
  end

  @doc "Records the group led by `os_pid` as started by the calling process."
  @spec register(non_neg_integer()) :: :ok
  def register(os_pid) when is_integer(os_pid) do
    case start_time(os_pid) do
      nil -> :ok
      started -> :ets.insert(@table, {self(), os_pid, started})
    end

    :ok
  end

  @doc "Forgets the group led by `os_pid` for the calling process."
  @spec unregister(non_neg_integer()) :: :ok
  def unregister(os_pid) when is_integer(os_pid) do
    :ets.match_delete(@table, {self(), os_pid, :_})
    :ok
  end

  @doc "Kills every group registered by `owner` (a worker pid) at once, and forgets them."
  @spec kill_owned_by(pid()) :: :ok
  def kill_owned_by(owner) when is_pid(owner) do
    groups = for {^owner, os_pid, started} <- :ets.lookup(@table, owner), do: {os_pid, started}

    # Forget them once they're dead (a caller killed mid-wait leaves them registered), or when
    # they can't be signalled at all (logged; nothing would ever retry).
    if signal_groups(groups, 0) != {:error, :survived}, do: :ets.delete(@table, owner)
    :ok
  end

  @doc """
  Stops the calling process's group led by `os_pid` gracefully: it gets a moment to exit by
  itself (e.g. codex on stdin EOF), then TERM, then KILL. Forgets the group.
  """
  @spec stop(non_neg_integer()) :: :ok
  def stop(os_pid) when is_integer(os_pid), do: stop_registered(os_pid, @exit_grace_ms)

  @doc "Kills the calling process's group led by `os_pid` right away (TERM, then KILL)."
  @spec kill(non_neg_integer()) :: :ok
  def kill(os_pid) when is_integer(os_pid), do: stop_registered(os_pid, 0)

  # A port the caller didn't register (or registered under another process) is identified by
  # its leader as it is now: the caller holds the port, so the group is still its own.
  defp stop_registered(os_pid, exit_grace_ms) do
    groups =
      case :ets.match_object(@table, {self(), os_pid, :_}) do
        [] -> [{os_pid, start_time(os_pid)}]
        entries -> for {_owner, ^os_pid, started} <- entries, do: {os_pid, started}
      end

    if signal_groups(groups, exit_grace_ms) != {:error, :survived}, do: unregister(os_pid)
    :ok
  end

  # :ok once every group is dead (or was never ours); {:error, :survived} if some outlived
  # KILL (e.g. stuck in uninterruptible I/O; callers keep them registered); {:error, :no_kill}
  # if nothing can be signalled.
  defp signal_groups([], _exit_grace_ms), do: :ok

  defp signal_groups(groups, exit_grace_ms) do
    case System.find_executable("kill") do
      nil ->
        Logger.error("Cannot signal process groups: no `kill` executable on PATH; #{length(groups)} may still be running")
        {:error, :no_kill}

      kill ->
        groups
        |> Enum.filter(&ours?(kill, &1))
        |> Enum.map(fn {os_pid, _started} -> os_pid end)
        |> wait_until_gone(kill, exit_grace_ms)
        |> tap(fn live -> Enum.each(live, &signal(kill, "TERM", &1)) end)
        |> wait_until_gone(kill, @term_grace_ms)
        |> tap(fn live -> Enum.each(live, &signal(kill, "KILL", &1)) end)
        |> wait_until_gone(kill, @kill_wait_ms)
        |> case do
          [] ->
            :ok

          survivors ->
            Logger.error("Process groups survived KILL (still registered): #{inspect(survivors)}")
            {:error, :survived}
        end
    end
  end

  # Still the group we registered: its leader is the same process (same start time), or the
  # leader is gone and the group lives on (a live group's id is never reused as a pid).
  defp ours?(kill, {os_pid, started}) do
    case start_time(os_pid) do
      nil -> signal(kill, "0", os_pid)
      ^started -> true
      _reused -> false
    end
  end

  defp wait_until_gone(pgids, kill, remaining_ms) do
    live = Enum.filter(pgids, &signal(kill, "0", &1))

    if live == [] or remaining_ms <= 0 do
      live
    else
      Process.sleep(@poll_ms)
      wait_until_gone(live, kill, remaining_ms - @poll_ms)
    end
  end

  defp signal(kill, signal, pgid) do
    {_output, status} = System.cmd(kill, ["-s", signal, "--", "-#{pgid}"], stderr_to_stdout: true)
    status == 0
  end

  # Process start time (clock ticks since boot, /proc/<pid>/stat field 22), nil if gone.
  defp start_time(os_pid) do
    # comm (field 2) is in parentheses and may itself contain ") ": split after the last ")".
    with {:ok, stat} <- File.read("/proc/#{os_pid}/stat"),
         {pos, 1} <- :binary.matches(stat, ")") |> List.last(),
         fields when length(fields) > 19 <- stat |> binary_part(pos + 1, byte_size(stat) - pos - 1) |> String.split() do
      Enum.at(fields, 19)
    else
      _ -> nil
    end
  end
end
