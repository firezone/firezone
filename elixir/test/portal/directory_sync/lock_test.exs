defmodule Portal.DirectorySync.LockTest do
  use Portal.DataCase, async: true

  import Portal.DirectorySyncLockHelpers

  alias Portal.DirectorySync.Lock
  alias Portal.Safe

  describe "try_run/3" do
    test "runs the function and releases the lock afterwards" do
      directory_id = Ecto.UUID.generate()

      assert Lock.try_run(:entra, directory_id, fn -> :first end) == {:ok, :first}
      assert Lock.try_run(:entra, directory_id, fn -> :second end) == {:ok, :second}
    end

    test "the function keeps its own database session while the lock is held" do
      directory_id = Ecto.UUID.generate()

      assert {:ok, {:ok, %{rows: [[1]]}}} =
               Lock.try_run(:entra, directory_id, fn ->
                 Safe.unscoped() |> Safe.query("SELECT 1", [])
               end)
    end

    test "is busy while another process holds the same directory" do
      directory_id = Ecto.UUID.generate()
      hold_directory_lock(:entra, directory_id)

      assert Lock.try_run(:entra, directory_id, fn -> :ran end) == :busy
      assert Lock.try_run(:google, directory_id, fn -> :ran end) == {:ok, :ran}
    end

    test "releases the lock when the function raises" do
      directory_id = Ecto.UUID.generate()

      assert_raise RuntimeError, "boom", fn ->
        Lock.try_run(:entra, directory_id, fn -> raise "boom" end)
      end

      assert Lock.try_run(:entra, directory_id, fn -> :ran end) == {:ok, :ran}
    end

    test "releases the lock when the caller is killed" do
      directory_id = Ecto.UUID.generate()
      test_pid = self()

      caller =
        spawn(fn ->
          Lock.try_run(:entra, directory_id, fn ->
            send(test_pid, :locked)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :locked
      assert Lock.try_run(:entra, directory_id, fn -> :ran end) == :busy

      Process.exit(caller, :kill)

      assert acquire_eventually(directory_id, 100) == {:ok, :ran}
    end
  end

  defp acquire_eventually(directory_id, attempts) do
    case Lock.try_run(:entra, directory_id, fn -> :ran end) do
      :busy when attempts > 0 ->
        Process.sleep(20)
        acquire_eventually(directory_id, attempts - 1)

      result ->
        result
    end
  end
end
