defmodule Portal.OpsTest do
  use Portal.DataCase, async: true
  import Portal.Ops
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.ClientFixtures
  import Portal.GatewayFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.TokenFixtures

  describe "count_presences/0" do
    test "returns presence counts grouped by topic prefix" do
      # Use unique topic names to avoid collisions with parallel tests
      unique_id = Ecto.UUID.generate()

      # Track actual presence entries using the Presence module
      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_clients:#{unique_id}", "client1", %{})

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_clients:#{unique_id}", "client2", %{})

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_gateways:#{unique_id}", "gw1", %{})

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_relays:#{unique_id}", "relay1", %{})

      result = count_presences()

      assert {"presences:test_clients", 2} in result
      assert {"presences:test_gateways", 1} in result
      assert {"presences:test_relays", 1} in result
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

      refute Repo.one(Portal.Account)
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

      banners = Repo.all(Portal.Banner)
      assert length(banners) == 1
      assert hd(banners).message == second.message
    end
  end

  describe "clear_banner/0" do
    test "removes all banners" do
      {:ok, _} = set_banner("Test message")
      assert Repo.aggregate(Portal.Banner, :count) == 1

      clear_banner()

      assert Repo.aggregate(Portal.Banner, :count) == 0
    end

    test "succeeds even when no banners exist" do
      assert {0, nil} = clear_banner()
    end
  end
end
