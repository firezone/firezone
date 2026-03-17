defmodule Portal.PG do
  @moduledoc """
  Targeted message delivery to processes across the cluster using named `:pg` process groups.

  Each process registers under its own ID. Messages are delivered directly to the registered
  process, avoiding the broadcast-to-all-nodes overhead of PubSub.

  Uses a named `:pg` scope isolated from the default scope used by replication, so an OTP bug
  in `pg.leave_remote/3` that can crash the pg GenServer does not affect the rest of the system.
  Channel processes monitor this scope and re-register if it crashes.
  """

  @doc """
  Registers the calling process under `key` with upsert semantics.

  Any existing process registered under `key` is sent `:disconnect` before the calling
  process joins, ensuring only one process per key is ever registered (e.g. on reconnection).
  """
  def register(key) do
    self = self()
    scope = scope()

    :pg.get_members(scope, key)
    |> Enum.each(fn pid -> if pid != self, do: send(pid, :disconnect) end)

    :pg.join(scope, key, self)
  end

  @doc """
  Delivers `message` to all processes registered under `key`.

  Returns `:ok` if at least one process is registered, `{:error, :not_found}` otherwise.
  """
  def deliver(key, message) do
    case :pg.get_members(scope(), key) do
      [] ->
        {:error, :not_found}

      pids ->
        Enum.each(pids, &send(&1, message))
        :ok
    end
  end

  @doc """
  Returns the pid of the pg scope process, or nil if not running.

  Channel processes should monitor this pid and re-register if it crashes,
  since the scope losing its state means all group memberships are lost.
  """
  def scope_pid, do: Process.whereis(scope())

  defp scope, do: Portal.Config.get_env(:portal, :pg_scope, __MODULE__)
end
