defmodule Portal.Mailer.RateLimiterTest do
  use ExUnit.Case, async: true
  import Portal.Mailer.RateLimiter

  describe "init/1" do
    test "creates a ETS table" do
      ets_table_name = random_table_name()
      assert {:ok, state} = init(prune_interval: 1, ets_table_name: ets_table_name)
      assert :ets.info(state.table)[:name] == ets_table_name
    end

    test "schedule a tick" do
      ets_table_name = random_table_name()
      assert {:ok, state} = init(prune_interval: 1, ets_table_name: ets_table_name)
      assert state.prune_interval == 1
      assert_receive :prune_expired_counters
    end
  end

  describe "prune_expired_counters/1" do
    test "prunes expired counters" do
      ets_table_name = random_table_name()
      init(ets_table_name: ets_table_name)

      now = :erlang.system_time(:millisecond)
      :ets.insert(ets_table_name, {:key, 1, now - 1})

      assert prune_expired_counters(ets_table_name) == 1
    end

    test "does not prune counters that did not expire" do
      ets_table_name = random_table_name()
      init(ets_table_name: ets_table_name)

      now = :erlang.system_time(:millisecond)
      :ets.insert(ets_table_name, {:key, 1, now + 1000})

      assert prune_expired_counters(ets_table_name) == 0
      assert :ets.tab2list(ets_table_name) == [{:key, 1, now + 1000}]
    end
  end

  describe "prune/1" do
    test "deletes all objects" do
      ets_table_name = random_table_name()
      init(ets_table_name: ets_table_name)

      :ets.insert(ets_table_name, {:key, 1, 1})
      :ets.insert(ets_table_name, {:key, 2, 2})

      assert prune(ets_table_name) == :ok
      assert :ets.tab2list(ets_table_name) == []
    end
  end

  describe "rate_limit/5" do
    test "executes the callback when not rate limited" do
      ets_table_name = random_table_name()
      init(ets_table_name: ets_table_name)

      callback = fn -> :executed end

      assert rate_limit(:key, 2, 1000, callback, ets_table_name) == {:ok, :executed}

      assert [{:key, 1, expires_at}] = :ets.tab2list(ets_table_name)
      assert expires_at > :erlang.system_time(:millisecond)
    end

    test "returns error when rate limited" do
      ets_table_name = random_table_name()
      init(ets_table_name: ets_table_name)

      callback = fn -> :executed end

      assert rate_limit(:key, 2, 10_000, callback, ets_table_name) == {:ok, :executed}
      assert rate_limit(:key, 2, 10_000, callback, ets_table_name) == {:ok, :executed}
      assert rate_limit(:key, 2, 10_000, callback, ets_table_name) == {:error, :rate_limited}
    end

    test "executes the callback when counter is exceeded but already expired" do
      ets_table_name = random_table_name()
      init(ets_table_name: ets_table_name)

      now = :erlang.system_time(:millisecond)

      callback = fn -> :executed end

      :ets.insert(ets_table_name, {:key, 1000, now - 1})

      assert rate_limit(:key, 2, 10_000, callback, ets_table_name) == {:ok, :executed}
      assert :ets.tab2list(ets_table_name) == []
    end
  end

  defp random_table_name do
    System.unique_integer() |> to_string() |> String.to_atom()
  end
end
