defmodule Portal.OpsTest do
  use Portal.DataCase, async: true
  import Portal.Ops
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.DeviceFixtures
  import Portal.PolicyFixtures
  import Portal.RelayFixtures
  import Portal.ResourceFixtures
  import Portal.TokenFixtures
  import Portal.ObanJobFixtures

  alias Portal.Mocks.Stripe
  alias Portal.Workers.DeleteAccount

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

  describe "sync_pricing_plans/0" do
    test "applies current Stripe product features and limits to accounts" do
      account =
        account_fixture(%{
          metadata: %{stripe: %{customer_id: "cus_sync123"}}
        })

      refute account.features.log_sinks

      customer =
        Stripe.build_customer(id: "cus_sync123", metadata: %{"account_id" => account.id})

      product =
        Stripe.build_product(
          id: "prod_test_enterprise",
          name: "Enterprise",
          metadata: Stripe.enterprise_metadata(%{"log_sinks" => true})
        )

      price = Stripe.build_price(product: "prod_test_enterprise")

      subscription =
        Stripe.build_subscription(
          customer: "cus_sync123",
          items: [[price: price, quantity: 42]]
        )

      subscriptions = %{"object" => "list", "has_more" => false, "data" => [subscription]}

      Stripe.stub(
        [{"GET", "/v1/subscriptions", 200, subscriptions}] ++
          Stripe.fetch_customer_endpoint(customer) ++
          Stripe.fetch_product_endpoint(product)
      )

      assert :ok = sync_pricing_plans()

      account = Repo.get!(Portal.Account, account.id)
      assert account.features.log_sinks
      assert account.features.idp_sync
      assert account.metadata.stripe.product_name == "Enterprise"
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

  describe "schedule_missing_account_deletion_jobs/0" do
    test "enqueues a delete job for accounts already pending deletion without a job" do
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      _active_account = account_fixture()

      assert {:ok, 1} = schedule_missing_account_deletion_jobs()

      scheduled_jobs =
        jobs_for_worker_and_arg("Portal.Workers.DeleteAccount", "account_id", account.id)

      assert length(scheduled_jobs) == 1

      [scheduled_job] = scheduled_jobs
      assert scheduled_job.state == "scheduled"
      assert DateTime.compare(scheduled_job.scheduled_at, account.scheduled_deletion_at) == :eq
    end

    test "does not enqueue duplicate delete jobs for accounts that already have one" do
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert {:ok, _job} =
               Oban.insert(
                 DeleteAccount.new(%{"account_id" => account.id}, scheduled_at: scheduled_deletion_at)
               )

      assert {:ok, 0} = schedule_missing_account_deletion_jobs()

      assert length(jobs_for_worker_and_arg("Portal.Workers.DeleteAccount", "account_id", account.id)) ==
               1
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
    import ExUnit.CaptureIO

    test "queues one batched email per account with enabled admins" do
      account1 = account_fixture()
      account2 = account_fixture()

      admin1 = admin_actor_fixture(account: account1)
      disabled_admin = admin_actor_fixture(account: account1)
      admin2 = admin_actor_fixture(account: account2)

      disabled_admin
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Repo.update!()

      capture_io("y\n", fn ->
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
                   bcc: [{"", String.downcase(admin1.email)}]
                 }
               ]

        assert collect_queued_emails(account2.id) == [
                 %{
                   subject: "Admin Subject",
                   html_body: "<p>Admin HTML</p>",
                   text_body: "Admin Text",
                   to: [],
                   bcc: [{"", String.downcase(admin2.email)}]
                 }
               ]
      end)
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

      capture_io("y\n", fn ->
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
                   bcc: [{"", String.downcase(enabled_admin.email)}]
                 }
               ]

        assert collect_queued_emails(disabled_account.id) == []
      end)
    end

    test "aborts when user declines confirmation" do
      account = account_fixture()
      admin_actor_fixture(account: account)

      capture_io("n\n", fn ->
        assert :aborted =
                 queue_admin_email(
                   [account.id],
                   "Subject",
                   "<p>HTML</p>",
                   "Text"
                 )

        assert collect_queued_emails(account.id) == []
      end)
    end

    test "normalizes admin emails to lowercase" do
      account = account_fixture()
      admin_actor_fixture(account: account, email: "Admin.User@Example.COM")

      capture_io("y\n", fn ->
        assert :ok =
                 queue_admin_email(
                   [account.id],
                   "Normalize Subject",
                   "<p>HTML</p>",
                   "Text"
                 )

        [email] = collect_queued_emails(account.id)
        [{_, addr}] = email.bcc
        assert addr == "admin.user@example.com"
      end)
    end

    test "chunks BCC recipients and globally sends 100 every 5 minutes" do
      account1 = account_fixture()
      account2 = account_fixture()

      Enum.each(1..60, fn i ->
        admin_actor_fixture(
          account: account1,
          email: "account-1-admin-#{String.pad_leading(to_string(i), 3, "0")}@example.com"
        )

        admin_actor_fixture(
          account: account2,
          email: "account-2-admin-#{String.pad_leading(to_string(i), 3, "0")}@example.com"
        )
      end)

      output =
        capture_io("y\n", fn ->
          assert :ok =
                   queue_admin_email(
                     [account1.id, account2.id],
                     "Chunk Subject",
                     "<p>Chunk HTML</p>",
                     "Chunk Text"
                   )

          jobs =
            [worker: Portal.Workers.OutboundEmail]
            |> Oban.Job.query()
            |> Repo.all()

          assert length(jobs) == 4

          available_recipients =
            jobs
            |> Enum.filter(&(&1.state == "available"))
            |> Enum.map(&length(&1.args["request"]["bcc"]))
            |> Enum.sum()

          assert available_recipients == 100
          assert [scheduled_job] = Enum.filter(jobs, &(&1.state == "scheduled"))
          assert length(scheduled_job.args["request"]["bcc"]) == 20

          assert DateTime.diff(scheduled_job.scheduled_at, scheduled_job.inserted_at, :second) in 299..300
        end)

      assert output =~ "120 unique admin(s)"
      assert output =~ "2 account(s)"
    end
  end
end
