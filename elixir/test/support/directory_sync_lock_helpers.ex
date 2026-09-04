defmodule Portal.DirectorySyncLockHelpers do
  @moduledoc false

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Portal.DirectorySync.Lock
  alias Portal.Repo

  @doc """
  Holds the directory lock from a second database session until the test
  exits, so the worker under test sees the directory as busy.
  """
  def hold_directory_lock(provider, directory_id) do
    test_pid = self()

    holder =
      spawn(fn ->
        :ok = Sandbox.checkout(Repo)

        {:ok, :released} =
          Lock.try_run(provider, directory_id, fn ->
            send(test_pid, {:holding_directory_lock, self()})

            receive do
              :release_directory_lock -> :released
            end
          end)

        Sandbox.checkin(Repo)
      end)

    receive do
      {:holding_directory_lock, ^holder} -> :ok
    after
      5_000 -> raise "could not take the directory lock from a second session"
    end

    on_exit(fn ->
      ref = Process.monitor(holder)
      send(holder, :release_directory_lock)

      receive do
        {:DOWN, ^ref, :process, ^holder, _reason} -> :ok
      end
    end)
  end
end
