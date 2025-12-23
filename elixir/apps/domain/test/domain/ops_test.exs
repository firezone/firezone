defmodule Domain.OpsTest do
  use Domain.DataCase, async: true
  import Domain.Ops
  import Domain.AccountFixtures
  import Domain.ActorFixtures
  import Domain.GroupFixtures
  import Domain.IdentityFixtures
  import Domain.ClientFixtures
  import Domain.GatewayFixtures
  import Domain.PolicyFixtures
  import Domain.RelayFixtures
  import Domain.ResourceFixtures
  import Domain.TokenFixtures

  describe "count_presences/1" do
    test "returns presence counts grouped by topic prefix" do
      table = :ets.new(:test_presences, [:set, :public])

      # Insert mock presence entries matching the Phoenix.Presence format
      :ets.insert(table, {{"presences:account_clients:acc1", self(), "client1"}, %{}, {1, 0}})
      :ets.insert(table, {{"presences:account_clients:acc1", self(), "client2"}, %{}, {2, 0}})
      :ets.insert(table, {{"presences:account_gateways:acc1", self(), "gw1"}, %{}, {3, 0}})
      :ets.insert(table, {{"presences:global_relays", self(), "relay1"}, %{}, {4, 0}})

      result = count_presences(table)

      assert {"presences:account_clients", 2} in result
      assert {"presences:account_gateways", 1} in result
      assert {"presences:global_relays", 1} in result

      :ets.delete(table)
    end

    test "returns empty list when no presences exist" do
      table = :ets.new(:test_presences_empty, [:set, :public])

      assert count_presences(table) == []

      :ets.delete(table)
    end
  end

  describe "delete_disabled_account/1" do
    test "doesn't delete an account that is not disabled" do
      account = account_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        delete_disabled_account(account.id)
      end
    end

    test "deletes account along with all related entities" do
      account = account_fixture()
      group_fixture(account: account)
      actor_fixture(type: :account_user, account: account)
      identity_fixture(account: account)
      client_fixture(account: account)
      gateway_fixture(account: account)
      policy_fixture(account: account)
      relay_fixture(account: account)
      resource_fixture(account: account)
      api_token_fixture(account: account)

      account =
        update_account(account, %{disabled_at: DateTime.utc_now(), disabled_reason: "Testing"})

      assert delete_disabled_account(account.id) == :ok

      assert_raise Ecto.NoResultsError, fn ->
        delete_disabled_account(account.id)
      end

      refute Repo.one(Domain.Account)
    end
  end

  describe "set_banner/1" do
    test "creates a banner with a message" do
      assert {:ok, banner} = set_banner("System maintenance scheduled")
      assert banner.message == "System maintenance scheduled"
    end

    test "replaces existing banner when setting a new one" do
      {:ok, _first} = set_banner("First message")
      {:ok, second} = set_banner("Second message")

      banners = Repo.all(Domain.Banner)
      assert length(banners) == 1
      assert hd(banners).message == second.message
    end

    test "returns error for invalid banner" do
      assert {:error, changeset} = set_banner(nil)
      assert errors_on(changeset) == %{message: ["can't be blank"]}
    end
  end

  describe "clear_banner/0" do
    test "removes all banners" do
      {:ok, _} = set_banner("Test message")
      assert Repo.aggregate(Domain.Banner, :count) == 1

      clear_banner()

      assert Repo.aggregate(Domain.Banner, :count) == 0
    end

    test "succeeds even when no banners exist" do
      assert {0, nil} = clear_banner()
    end
  end
end
