defmodule Portal.OpsTest do
  use Portal.DataCase, async: true
  import Portal.Ops
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers
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

  describe "queue_admin_email/4" do
    test "queues one batched email per account with enabled admins" do
      account1 = account_fixture()
      account2 = account_fixture()

      admin1 = admin_actor_fixture(account: account1)
      disabled_admin = admin_actor_fixture(account: account1)
      admin2 = admin_actor_fixture(account: account2)

      disabled_admin
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

      assert :ok =
               queue_admin_email(
                 [account1.id, account2.id],
                 "Admin Subject",
                 "<p>Admin HTML</p>",
                 "Admin Text"
               )

      assert collect_queued_emails(account1.id) == [
               %{
                 subject: "Admin Subject",
                 html_body: "<p>Admin HTML</p>",
                 text_body: "Admin Text",
                 to: [],
                 bcc: [{"", admin1.email}]
               }
             ]

      assert collect_queued_emails(account2.id) == [
               %{
                 subject: "Admin Subject",
                 html_body: "<p>Admin HTML</p>",
                 text_body: "Admin Text",
                 to: [],
                 bcc: [{"", admin2.email}]
               }
             ]
    end

    test "skips disabled accounts when queuing for :all" do
      enabled_account = account_fixture()
      disabled_account = account_fixture()

      enabled_admin = admin_actor_fixture(account: enabled_account)
      _disabled_admin = admin_actor_fixture(account: disabled_account)

      update_account(disabled_account, %{
        disabled_at: DateTime.utc_now(),
        disabled_reason: "Testing"
      })

      assert :ok =
               queue_admin_email(
                 :all,
                 "Admin Subject",
                 "<p>Admin HTML</p>",
                 "Admin Text"
               )

      assert collect_queued_emails(enabled_account.id) == [
               %{
                 subject: "Admin Subject",
                 html_body: "<p>Admin HTML</p>",
                 text_body: "Admin Text",
                 to: [],
                 bcc: [{"", enabled_admin.email}]
               }
             ]

      assert collect_queued_emails(disabled_account.id) == []
    end
  end
end
