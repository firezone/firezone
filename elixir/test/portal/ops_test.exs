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
  import Portal.SlugRegistryHelpers
  import ExUnit.CaptureLog
  import Plug.Conn

  alias Portal.Mocks.Stripe
  alias Portal.Workers.DeleteAccount

  describe "count_global_presences/0" do
    test "returns cluster-wide presence counts grouped by topic prefix" do
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

      result = count_global_presences()

      assert {"presences:test_clients", 2} in result
      assert {"presences:test_gateways", 1} in result
      assert {"presences:test_relays", 1} in result
    end
  end

  describe "count_local_presences/0" do
    test "returns local presence counts grouped by topic prefix" do
      unique_id = Ecto.UUID.generate()

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_clients:#{unique_id}", "client1", %{})

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_clients:#{unique_id}", "client2", %{})

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_gateways:#{unique_id}", "gw1", %{})

      {:ok, _} =
        Portal.Presence.track(self(), "presences:test_relays:#{unique_id}", "relay1", %{})

      result = count_local_presences()

      assert {"presences:test_clients", 2} in result
      assert {"presences:test_gateways", 1} in result
      assert {"presences:test_relays", 1} in result
    end
  end

  describe "count_regional_presences/1" do
    test "returns presence counts for nodes in the requested region" do
      unique_id = Ecto.UUID.generate()
      region = "centralus-#{unique_id}"
      prefix = "presences:regional_clients_#{unique_id}"
      Portal.Config.put_env_override(:portal, :region, region)

      {:ok, _} = Portal.Presence.track(self(), "#{prefix}:account", "client1", %{})
      {:ok, _} = Portal.Presence.track(self(), "#{prefix}:account", "client2", %{})

      assert {prefix, 2} in count_regional_presences(region)
      refute {prefix, 2} in count_regional_presences("another-region")
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
        update_account(account, %{is_disabled: true, disabled_reason: "Testing"})

      assert delete_disabled_account(account.id) == :ok

      assert_raise Ecto.NoResultsError, fn ->
        delete_disabled_account(account.id)
      end

      refute Repo.one(Portal.Account)
    end

    test "queues the cancellation of the account's Stripe subscriptions" do
      account =
        update_account(account_fixture(), %{
          is_disabled: true,
          metadata: %{stripe: %{customer_id: "cus_deleted"}}
        })

      assert delete_disabled_account(account.id) == :ok

      assert [job] =
               jobs_for_worker_and_arg(
                 "Portal.Workers.DeleteSubscription",
                 "customer_id",
                 "cus_deleted"
               )

      assert job.args == %{"customer_id" => "cus_deleted"}
    end
  end

  describe "backfill_slug_registry/0" do
    import ExUnit.CaptureIO

    test "does nothing with the local registry" do
      account_fixture()

      output = capture_io(fn -> assert {:error, :no_registry} = backfill_slug_registry() end)

      assert output =~ "SLUG_REGISTRY_TABLE_URL is not set"
    end

    test "aborts without confirmation" do
      account_fixture(slug: "keep-local")
      use_azure_registry(:us)
      test_pid = self()

      stub_registry(fn conn ->
        send(test_pid, :registry_called)
        send_resp(conn, 204, "")
      end)

      output = capture_io("n\n", fn -> assert :aborted = backfill_slug_registry() end)

      assert output =~ "About to claim 1 slug(s) for region us"
      assert output =~ "Aborted."
      refute_received :registry_called
    end

    test "claims every local slug in the registry" do
      account = account_fixture(slug: "backfill-me")
      update_account(account, slug: "backfill-me-too")
      use_azure_registry(:us)
      test_pid = self()

      stub_registry(fn
        %{method: "POST", request_path: "/slugs"} = conn ->
          send(test_pid, {:claimed, json_body(conn)["RowKey"]})
          send_resp(conn, 204, "")
      end)

      output = capture_io("y\n", fn -> assert {:ok, 2} = backfill_slug_registry() end)

      assert output =~ "Claimed 2 slug(s)."
      assert_received {:claimed, "backfill_me"}
      assert_received {:claimed, "backfill_me_too"}
    end

    test "prints a slug that another account holds and goes on" do
      account = account_fixture(slug: "contested")
      use_azure_registry(:us)

      stub_registry(fn
        %{method: "POST"} = conn -> send_resp(conn, 409, "")
        %{method: "GET"} = conn -> Req.Test.json(conn, entity("contested", Ecto.UUID.generate(), "eu"))
      end)

      output = capture_io("y\n", fn -> assert {:ok, 0} = backfill_slug_registry() end)

      assert output =~ "contested: another account holds this slug"
      assert output =~ account.id
    end

    test "stops when the registry is unavailable" do
      account_fixture()
      use_azure_registry(:us)
      stub_registry(fn conn -> send_resp(conn, 503, "") end)

      output =
        capture_io("y\n", fn ->
          capture_log(fn -> assert {:error, :slug_registry_unavailable} = backfill_slug_registry() end)
        end)

      assert output =~ "The slug registry is unavailable."
    end
  end

  describe "schedule_missing_account_deletion_jobs/0" do
    test "enqueues a delete job for accounts already pending deletion without a job" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(now, 7, :day)

      account =
        update_account(account_fixture(),
          is_disabled: true,
          scheduled_deletion_at: scheduled_deletion_at
        )

      _enabled_account = account_fixture()

      assert {:ok, 1} = schedule_missing_account_deletion_jobs()

      scheduled_jobs =
        jobs_for_worker_and_arg("Portal.Workers.DeleteAccount", "account_id", account.id)

      assert length(scheduled_jobs) == 1

      [scheduled_job] = scheduled_jobs
      assert scheduled_job.state == "scheduled"
      assert DateTime.compare(scheduled_job.scheduled_at, account.scheduled_deletion_at) == :eq
    end

    test "does not enqueue duplicate delete jobs for accounts that already have one" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(now, 7, :day)

      account =
        update_account(account_fixture(),
          is_disabled: true,
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

  describe "backfill_relay_throughput_limits/0" do
    test "sets the plan default on accounts without a limit" do
      starter = starter_account_fixture()
      team = team_account_fixture()
      business = business_account_fixture()

      enterprise =
        update_account(account_fixture(), metadata: %{stripe: %{product_name: "Enterprise (Annual)"}})

      unknown = account_fixture()
      limited = update_account(team_account_fixture(), limits: %{relay_throughput_mbps: 100})

      assert {:ok, 4} = backfill_relay_throughput_limits()

      assert fetch_account!(starter.id).limits.relay_throughput_mbps == 5
      assert fetch_account!(team.id).limits.relay_throughput_mbps == 15
      assert fetch_account!(business.id).limits.relay_throughput_mbps == 25
      assert fetch_account!(enterprise.id).limits.relay_throughput_mbps == 50
      assert fetch_account!(unknown.id).limits.relay_throughput_mbps == nil
      assert fetch_account!(limited.id).limits.relay_throughput_mbps == 100
      assert fetch_account!(team.id).limits.monthly_active_users_count == 100

      assert {:ok, 0} = backfill_relay_throughput_limits()
    end
  end

  describe "backfill_relay_allocation_limits/0" do
    test "sets the plan default on accounts without a limit" do
      starter = starter_account_fixture()
      team = team_account_fixture()
      business = business_account_fixture()

      enterprise =
        update_account(account_fixture(), metadata: %{stripe: %{product_name: "Enterprise (Annual)"}})

      unknown = account_fixture()
      limited = update_account(team_account_fixture(), limits: %{relay_allocations_count: 100})

      assert {:ok, 3} = backfill_relay_allocation_limits()

      assert fetch_account!(starter.id).limits.relay_allocations_count == 64
      assert fetch_account!(team.id).limits.relay_allocations_count == 1024
      assert fetch_account!(business.id).limits.relay_allocations_count == 2048
      assert fetch_account!(enterprise.id).limits.relay_allocations_count == nil
      assert fetch_account!(unknown.id).limits.relay_allocations_count == nil
      assert fetch_account!(limited.id).limits.relay_allocations_count == 100
      assert fetch_account!(team.id).limits.monthly_active_users_count == 100

      assert {:ok, 0} = backfill_relay_allocation_limits()
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
      account1 = active_account_fixture()
      account2 = active_account_fixture()

      admin1 = admin_actor_fixture(account: account1)
      disabled_admin = admin_actor_fixture(account: account1)
      admin2 = admin_actor_fixture(account: account2)

      disabled_admin
      |> Ecto.Changeset.change(is_disabled: true)
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
      enabled_account = active_account_fixture()
      disabled_account = active_account_fixture()

      enabled_admin = admin_actor_fixture(account: enabled_account)
      _disabled_admin = admin_actor_fixture(account: disabled_account)

      update_account(disabled_account, %{
        is_disabled: true,
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
      account = active_account_fixture()
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
      account = active_account_fixture()
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

    test "keeps each account in one send window" do
      account1 = active_account_fixture()
      account2 = active_account_fixture()

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

      started_at = DateTime.utc_now()

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

          states_by_account =
            jobs
            |> Enum.group_by(& &1.args["account_id"])
            |> Enum.map(fn {_account_id, account_jobs} ->
              recipient_count =
                account_jobs
                |> Enum.map(&length(&1.args["request"]["bcc"]))
                |> Enum.sum()

              assert recipient_count == 60
              assert [state] = Enum.uniq(Enum.map(account_jobs, & &1.state))
              state
            end)

          assert Enum.sort(states_by_account) == ["available", "scheduled"]

          scheduled_jobs = Enum.filter(jobs, &(&1.state == "scheduled"))
          assert length(scheduled_jobs) == 2
          assert length(Enum.uniq(Enum.map(scheduled_jobs, & &1.scheduled_at))) == 1

          finished_at = DateTime.utc_now()

          assert Enum.all?(scheduled_jobs, fn job ->
                   DateTime.diff(job.scheduled_at, started_at, :second) >= 295 and
                     DateTime.diff(job.scheduled_at, finished_at, :second) <= 305
                 end)

          assert Enum.all?(jobs, fn job ->
                   length(job.args["request"]["bcc"]) <= 50
                 end)
        end)

      assert output =~ "120 unique admin(s)"
      assert output =~ "2 account(s)"
    end

    test "skips accounts with no session logs" do
      active_account = active_account_fixture()
      dormant_account = account_fixture()

      active_admin = admin_actor_fixture(account: active_account)
      admin_actor_fixture(account: dormant_account)

      capture_io("y\n", fn ->
        assert :ok =
                 queue_admin_email(
                   [active_account.id, dormant_account.id],
                   "Admin Subject",
                   "<p>Admin HTML</p>",
                   "Admin Text"
                 )

        assert [%{bcc: [{"", email}]}] = collect_queued_emails(active_account.id)
        assert email == String.downcase(active_admin.email)

        assert collect_queued_emails(dormant_account.id) == []
      end)
    end

    test "emails a paid account with no session logs" do
      account = team_account_fixture()
      admin = admin_actor_fixture(account: account)

      output =
        capture_io("y\n", fn ->
          assert :ok =
                   queue_admin_email(
                     [account.id],
                     "Admin Subject",
                     "<p>Admin HTML</p>",
                     "Admin Text"
                   )

          assert [%{bcc: [{"", email}]}] = collect_queued_emails(account.id)
          assert email == String.downcase(admin.email)
        end)

      refute output =~ "dormant"
    end

    test "errors without prompting when every account is dormant" do
      account = account_fixture()
      admin_actor_fixture(account: account)

      output =
        capture_io(fn ->
          assert {:error, :no_recipients} =
                   queue_admin_email(
                     [account.id],
                     "Admin Subject",
                     "<p>Admin HTML</p>",
                     "Admin Text"
                   )
        end)

      assert output =~ "Skipping 1 dormant account(s)"
      assert output =~ "No admin recipients found."
      refute output =~ "Continue?"
      assert collect_queued_emails(account.id) == []
    end

    test "errors when no account has an enabled admin" do
      account = active_account_fixture()

      output =
        capture_io(fn ->
          assert {:error, :no_recipients} =
                   queue_admin_email(
                     [account.id],
                     "Admin Subject",
                     "<p>Admin HTML</p>",
                     "Admin Text"
                   )
        end)

      assert output =~ "No admin recipients found."
      refute output =~ "dormant"
    end
  end

  describe "queue_product_announcement/4" do
    import ExUnit.CaptureIO

    test "queues one email per admin with a link to turn announcements off" do
      account = active_account_fixture()
      admin1 = admin_actor_fixture(account: account)
      admin2 = admin_actor_fixture(account: account)
      actor_fixture(account: account, type: :account_user)

      capture_io("y\n", fn ->
        assert :ok =
                 queue_product_announcement(
                   [account.id],
                   "What's new",
                   "<p>New features</p>",
                   "New features"
                 )
      end)

      emails = collect_queued_emails(account.id)

      assert emails |> Enum.flat_map(& &1.to) |> Enum.sort() ==
               Enum.sort([{"", admin1.email}, {"", admin2.email}])

      for email <- emails do
        assert email.subject == "What's new"
        assert email.html_body =~ "<p>New features</p>"
        assert email.text_body =~ "New features"
        assert email.text_body =~ "/#{account.id}/unsubscribe/"
      end

      tokens =
        Enum.map(emails, fn email ->
          [token] =
            Regex.run(~r{/#{account.id}/unsubscribe/([A-Za-z0-9_.-]+)}, email.text_body,
              capture: :all_but_first
            )

          {:ok, payload} = Portal.UnsubscribeToken.verify(token)
          payload
        end)

      assert Enum.sort(tokens) ==
               Enum.sort([
                 {account.id, admin1.id, :product_announcements},
                 {account.id, admin2.id, :product_announcements}
               ])
    end

    test "sends only to enabled admins" do
      account = active_account_fixture()
      admin = admin_actor_fixture(account: account)
      actor_fixture(account: account, type: :account_user)
      disabled_actor_fixture(account: account, type: :account_admin_user)

      capture_io("y\n", fn ->
        assert :ok = queue_product_announcement([account.id], "What's new", "<p>Hi</p>", "Hi")
      end)

      assert [email] = collect_queued_emails(account.id)
      assert email.to == [{"", admin.email}]
    end

    test "skips admins who turned product announcements off" do
      account = active_account_fixture()
      admin = admin_actor_fixture(account: account)
      opted_out = admin_actor_fixture(account: account)
      actor_preferences_fixture(opted_out, notifications: %{product_announcements: []})

      capture_io("y\n", fn ->
        assert :ok = queue_product_announcement([account.id], "What's new", "<p>Hi</p>", "Hi")
      end)

      assert [email] = collect_queued_emails(account.id)
      assert email.to == [{"", admin.email}]
    end

    test "sends once to a person who is an admin of two accounts" do
      account1 = active_account_fixture()
      account2 = active_account_fixture()
      email = "shared-#{System.unique_integer([:positive])}@example.com"
      admin_actor_fixture(account: account1, email: email)
      admin_actor_fixture(account: account2, email: email)

      output =
        capture_io("y\n", fn ->
          assert :ok =
                   queue_product_announcement(
                     [account1.id, account2.id],
                     "What's new",
                     "<p>Hi</p>",
                     "Hi"
                   )
        end)

      assert output =~ "to 1 unique admin(s)"

      assert length(collect_queued_emails(account1.id) ++ collect_queued_emails(account2.id)) ==
               1
    end

    test "aborts when user declines confirmation" do
      account = active_account_fixture()
      admin_actor_fixture(account: account)

      capture_io("n\n", fn ->
        assert :aborted =
                 queue_product_announcement([account.id], "What's new", "<p>Hi</p>", "Hi")
      end)

      assert collect_queued_emails(account.id) == []
    end

    test "errors when every admin turned product announcements off" do
      account = active_account_fixture()
      admin = admin_actor_fixture(account: account)
      actor_preferences_fixture(admin, notifications: %{product_announcements: []})

      output =
        capture_io(fn ->
          assert {:error, :no_recipients} =
                   queue_product_announcement([account.id], "What's new", "<p>Hi</p>", "Hi")
        end)

      assert output =~ "No admin recipients found."
    end
  end
end
