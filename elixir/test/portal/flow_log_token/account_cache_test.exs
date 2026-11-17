defmodule Portal.FlowLogToken.AccountCacheTest do
  use ExUnit.Case, async: true

  alias Portal.{Account, Changes.Change, PubSub}
  alias Portal.FlowLogToken.AccountCache

  setup do
    %{account_id: Ecto.UUID.generate()}
  end

  defp loader(result) do
    test_pid = self()

    fn ->
      send(test_pid, :loaded)
      result
    end
  end


  describe "fetch/2" do
    test "remembers an id with no account", %{account_id: account_id} do
      assert AccountCache.fetch(account_id, loader(nil)) == nil
      assert AccountCache.fetch(account_id, loader(nil)) == nil

      assert_received :loaded
      refute_received :loaded
    end

    test "stops remembering ids with no account once the cache is full", %{account_id: account_id} do
      Portal.Config.put_env_override(AccountCache, max_entries: 0)

      assert AccountCache.fetch(account_id, loader(nil)) == nil
      assert AccountCache.fetch(account_id, loader(nil)) == nil

      assert_received :loaded
      assert_received :loaded
    end

    test "remembers an account", %{account_id: account_id} do
      account = %Account{id: account_id}

      assert AccountCache.fetch(account_id, loader(account)) == account
      assert AccountCache.fetch(account_id, loader(account)) == account

      # Loaded once before watching for changes and once after.
      assert_received :loaded
      assert_received :loaded
      refute_received :loaded
    end

    test "remembers an account even when the cache is full", %{account_id: account_id} do
      Portal.Config.put_env_override(AccountCache, max_entries: 0)
      account = %Account{id: account_id}

      assert AccountCache.fetch(account_id, loader(account)) == account
      assert AccountCache.fetch(account_id, loader(account)) == account

      assert_received :loaded
      assert_received :loaded
      refute_received :loaded
    end
  end

  describe "changes" do
    test "an inserted account replaces a remembered missing id", %{account_id: account_id} do
      assert AccountCache.fetch(account_id, loader(nil)) == nil

      account = %Account{id: account_id}
      change = %Change{lsn: 1, op: :insert, struct: account}
      :ok = PubSub.Changes.broadcast_account(change)
      await_eviction(account_id)

      assert AccountCache.fetch(account_id, loader(account)) == account
    end

    test "an update to an account drops it", %{account_id: account_id} do
      old = %Account{id: account_id, ingest_signing_key: "old"}
      new = %Account{id: account_id, ingest_signing_key: "new"}
      assert AccountCache.fetch(account_id, loader(old)) == old

      change = %Change{lsn: 1, op: :update, old_struct: old, struct: new}
      :ok = PubSub.Changes.broadcast(account_id, :accounts, change)
      await_eviction(account_id)

      assert AccountCache.fetch(account_id, loader(new)) == new
    end

    test "a deleted account is forgotten", %{account_id: account_id} do
      account = %Account{id: account_id}
      assert AccountCache.fetch(account_id, loader(account)) == account

      change = %Change{lsn: 1, op: :delete, old_struct: account}
      :ok = PubSub.Changes.broadcast(account_id, :accounts, change)
      await_eviction(account_id)

      assert AccountCache.fetch(account_id, loader(nil)) == nil
    end
  end

  # The change reaches each subscriber in turn, so the cache may handle it
  # after the broadcast returns.
  defp await_eviction(account_id, attempts \\ 1_000) do
    cond do
      :ets.lookup(AccountCache, account_id) == [] -> :ok
      attempts == 0 -> flunk("the cache kept #{account_id}")
      true ->
        Process.sleep(1)
        await_eviction(account_id, attempts - 1)
    end
  end
end
