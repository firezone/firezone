defmodule Domain.Jobs.Executors.ConcurrentTest do
  use Domain.DataCase, async: true
  alias Domain.Fixtures
  import Domain.Jobs.Executors.Concurrent

  def state(config) do
    {:ok, {:state, config}}
  end

  def execute({:state, config}) do
    send(config[:test_pid], {:executed, self(), :erlang.monotonic_time()})
    :ok
  end

  test "executes the handler on the interval" do
    assert {:ok, _pid} = start_link({__MODULE__, 25, test_pid: self()})

    assert_receive {:executed, _pid, time1}, 500
    assert_receive {:executed, _pid, time2}, 500

    assert time1 < time2
  end

  test "delays initial message by the initial_delay" do
    assert {:ok, _pid} =
             start_link({
               __MODULE__,
               25,
               test_pid: self(), initial_delay: 100
             })

    refute_receive {:executed, _pid, _time}, 50
    assert_receive {:executed, _pid, _time}, 1000
  end

  describe "reject_locked/2" do
    test "returns all rows if none are locked" do
      account1 = Fixtures.Accounts.create_account()
      account2 = Fixtures.Accounts.create_account()
      rows = [account1, account2]

      Domain.Repo.checkout(fn ->
        assert reject_locked("accounts", rows) == rows
      end)
    end

    test "does not allow two processes to lock the same rows" do
      account1 = Fixtures.Accounts.create_account()
      account2 = Fixtures.Accounts.create_account()
      rows = [account1, account2]

      test_pid = self()

      task1 =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Domain.Repo)

          Domain.Repo.checkout(fn ->
            rows = reject_locked("accounts", rows)
            send(test_pid, {:locked, rows})
            Process.sleep(300)
          end)
        end)

      task2 =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Domain.Repo)

          Domain.Repo.checkout(fn ->
            rows = reject_locked("accounts", rows)
            send(test_pid, {:locked, rows})
            Process.sleep(300)
          end)
        end)

      assert_receive {:locked, rows1}
      assert_receive {:locked, rows2}
      assert length(rows1) + length(rows2) == length(rows)

      Task.ignore(task1)
      Task.ignore(task2)
    end
  end
end
