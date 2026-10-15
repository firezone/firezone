defmodule Portal.Workers.AccountInactivityReminderTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.AccountInactivityReminder

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures
  import Portal.PolicyFixtures
  import Portal.ResourceFixtures
  import Portal.SessionLogFixtures
  import Portal.SiteFixtures

  defp inactive_account_fixture do
    last_active_at = DateTime.add(DateTime.utc_now(), -400, :day)
    update_account(starter_account_fixture(), last_active_at: last_active_at)
  end

  defp configure_acs_secondary(status \\ 202) do
    Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
      adapter: Swoosh.Adapters.AzureCommunicationServices,
      endpoint: "https://acs.example.com",
      auth: "acs-token",
      req_opts: [plug: {Req.Test, Portal.AzureCommunicationServices}, retry: false]
    )

    test_pid = self()

    Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:acs_body, JSON.decode!(body)})

      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(acs_response(status))
    end)
  end

  defp acs_response(202), do: %{"id" => Ecto.UUID.generate(), "status" => "Running"}
  defp acs_response(_status), do: %{"error" => %{"message" => "failure"}}

  defp perform_reminder(account, reason \\ "inactive") do
    perform_job(AccountInactivityReminder, %{"account_id" => account.id, "reason" => reason})
  end

  defp default_setup_account_fixture do
    account = starter_account_fixture()
    admin_actor_fixture(account: account)
    site_fixture(account: account, name: "Default Site")
    internet_resource_fixture(account: account, site: internet_site_fixture(account: account))
    owner = group_fixture(account: account, name: "Account owner")
    managed_group_fixture(account: account, name: "Everyone")
    pool = own_devices_pool_resource_fixture(account: account, name: "My devices")
    policy_fixture(account: account, group: owner, resource: pool)
    account
  end

  describe "perform/1" do
    test "sends the reminder once and starts the reminder period" do
      configure_acs_secondary()
      account = inactive_account_fixture()
      admin_actor_fixture(account: account)

      assert :ok = perform_reminder(account)
      assert Repo.reload!(account).inactivity_reminded_at

      assert :ok = perform_reminder(account)
      assert Repo.aggregate(Portal.OutboundEmail, :count) == 1

      assert_received {:acs_body, %{"content" => %{"plainText" => body}}}
      assert body =~ "12 months"
      assert body =~ "two weeks"
      assert body =~ "/#{account.slug}/sign_in"
    end

    test "skips an account with activity since it was queued" do
      configure_acs_secondary()
      account = inactive_account_fixture()
      admin_actor_fixture(account: account)
      session_log_fixture(account: account)

      assert :ok = perform_reminder(account)

      assert is_nil(Repo.reload!(account).inactivity_reminded_at)
      refute_received {:acs_body, _body}
    end

    test "sends a default reminder without a year of inactivity" do
      configure_acs_secondary()
      account = starter_account_fixture()
      admin_actor_fixture(account: account)

      assert :ok = perform_reminder(account, "default")

      assert Repo.reload!(account).inactivity_reminded_at
      assert_received {:acs_body, %{"content" => %{"plainText" => body}}}
      assert body =~ "no setup beyond what was created at sign-up"
    end

    test "skips a default reminder for an account set up since it was queued" do
      configure_acs_secondary()
      account = starter_account_fixture()
      admin_actor_fixture(account: account)
      resource_fixture(account: account)

      assert :ok = perform_reminder(account, "default")

      assert is_nil(Repo.reload!(account).inactivity_reminded_at)
      refute_received {:acs_body, _body}
    end

    test "keeps the reminder period closed when delivery fails" do
      configure_acs_secondary(422)
      account = inactive_account_fixture()
      admin_actor_fixture(account: account)

      assert {:error, _reason} = perform_reminder(account)

      assert is_nil(Repo.reload!(account).inactivity_reminded_at)
    end

    test "keeps the reminder period closed when every admin is suppressed" do
      configure_acs_secondary()
      account = inactive_account_fixture()
      admin = admin_actor_fixture(account: account)

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email(admin.email)
      })

      assert :ok = perform_reminder(account)

      assert is_nil(Repo.reload!(account).inactivity_reminded_at)
      refute_received {:acs_body, _body}
    end
  end

  describe "default_accounts_query/0" do
    test "includes accounts with only what sign-up creates" do
      account = default_setup_account_fixture()

      ids = AccountInactivityReminder.default_accounts_query() |> Repo.all() |> Enum.map(& &1.id)

      assert account.id in ids
    end

    test "excludes accounts with setup, activity, or a paid plan" do
      configured = starter_account_fixture()
      admin_actor_fixture(account: configured)
      resource_fixture(account: configured)

      used = starter_account_fixture()
      admin_actor_fixture(account: used)
      session_log_fixture(account: used)

      paid = team_account_fixture()
      admin_actor_fixture(account: paid)

      ids = AccountInactivityReminder.default_accounts_query() |> Repo.all() |> Enum.map(& &1.id)

      refute configured.id in ids
      refute used.id in ids
      refute paid.id in ids
    end
  end

  describe "enqueue_default/0" do
    test "queues at most 100 reminders and skips pending ones" do
      for _ <- 1..101 do
        admin_actor_fixture(account: starter_account_fixture())
      end

      assert {:ok, 100} = AccountInactivityReminder.enqueue_default()
      assert {:ok, 1} = AccountInactivityReminder.enqueue_default()
      assert {:ok, 0} = AccountInactivityReminder.enqueue_default()
      assert length(all_enqueued(worker: AccountInactivityReminder)) == 101
    end
  end
end
