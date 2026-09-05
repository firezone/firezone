defmodule Portal.DirectorySync.Lock do
  @moduledoc false

  @doc """
  Runs `fun` while holding a session advisory lock for one directory.

  The lock is deliberately shared by full-sync and webhook workers. Using a
  PostgreSQL session lock makes acquisition atomic and releases the lock if the
  worker process or database connection exits unexpectedly.
  """
  def try_run(provider, directory_id, fun) when is_function(fun, 0) do
    key = "directory_sync:#{provider}:#{directory_id}"

    __MODULE__.Database.try_run(key, fun)
  end

  defmodule Database do
    alias Portal.Safe

    # A linked holder process keeps the lock on its own connection from the
    # direct lock pool, so `fun` runs its queries on the job pool with the
    # usual per-query timeouts, and the lock still dies with the caller.
    def try_run(key, fun) do
      caller = self()
      ref = make_ref()
      holder = spawn_link(fn -> hold(key, caller, ref) end)
      monitor = Process.monitor(holder)

      receive do
        {^ref, :acquired} ->
          try do
            {:ok, fun.()}
          after
            release(holder, ref, monitor)
          end

        {^ref, :busy} ->
          Process.demonitor(monitor, [:flush])
          :busy

        {:DOWN, ^monitor, :process, ^holder, reason} ->
          exit({:directory_lock, reason})
      end
    end

    defp hold(key, caller, ref) do
      Safe.unscoped(Portal.Repo.Lock)
      |> Safe.checkout(
        fn ->
          if lock(key) do
            send(caller, {ref, :acquired})

            receive do
              {^ref, :release} -> unlock(key)
            end
          else
            send(caller, {ref, :busy})
          end
        end,
        timeout: :infinity
      )
    rescue
      # No free lock connection is the same as a held lock: try again later
      error in DBConnection.ConnectionError ->
        if error.reason == :queue_timeout do
          send(caller, {ref, :busy})
        else
          reraise error, __STACKTRACE__
        end
    end

    defp lock(key) do
      {:ok, %{rows: [[acquired?]]}} =
        Safe.unscoped(Portal.Repo.Lock)
        |> Safe.query("SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [key])

      acquired?
    end

    # A closed connection has already dropped the lock, so the result does not matter
    defp unlock(key) do
      Safe.unscoped(Portal.Repo.Lock)
      |> Safe.query("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [key])
    end

    defp release(holder, ref, monitor) do
      send(holder, {ref, :release})

      receive do
        {:DOWN, ^monitor, :process, ^holder, _reason} -> :ok
      end
    end
  end
end
