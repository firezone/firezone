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

    def try_run(key, fun) do
      Safe.unscoped()
      |> Safe.checkout(fn ->
        {:ok, %{rows: [[acquired?]]}} =
          Safe.unscoped()
          |> Safe.query("SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [key])

        if acquired? do
          try do
            {:ok, fun.()}
          after
            {:ok, _} =
              Safe.unscoped()
              |> Safe.query("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [key])
          end
        else
          :busy
        end
      end)
    end
  end
end
