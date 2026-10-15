defmodule Portal.Accounts.InactivityTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.SessionLogFixtures
  import Portal.SiteFixtures
  import Portal.ResourceFixtures

  alias Portal.Accounts.Inactivity
  alias Portal.Workers.AccountInactivityReminder

  defp age(account, attrs \\ []) do
    account
    |> change(
      Keyword.merge([last_active_at: DateTime.add(DateTime.utc_now(), -400, :day)], attrs)
    )
    |> Repo.update!()
  end

  defp preview_ids do
    Portal.Ops.default_accounts_query() |> Repo.all() |> Enum.map(& &1.id)
  end

  defp acs_response(status \\ 202) do
    Portal.Config.put_env_override(:portal, Portal.Mailer.Secondary,
      adapter: Swoosh.Adapters.AzureCommunicationServices,
      endpoint: "https://acs.example.com",
      access_key: Base.encode64("test-secret"),
      req_opts: [plug: {Req.Test, Portal.AzureCommunicationServices}, retry: false]
    )

    test_pid = self()

    Req.Test.stub(Portal.AzureCommunicationServices, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:acs_request, JSON.decode!(body)})

      if status == 202 do
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"id" => Ecto.UUID.generate(), "status" => "Running"})
      else
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"error" => %{"message" => "failure"}})
      end
    end)
  end

  defp send_reminder(account, reason \\ "inactive") do
    perform_job(AccountInactivityReminder, %{"account_id" => account.id, "reason" => reason})
  end

  test "new accounts start their inactivity clock today" do
    account = starter_account_fixture()
    assert abs(DateTime.diff(DateTime.utc_now(), account.last_active_at)) < 5
    assert is_nil(account.inactivity_reminded_at)
    assert {:ok, 0} = Inactivity.sweep()
  end

  test "daily rollup persists activity, clears warnings, and never moves activity backwards" do
    now = DateTime.utc_now()

    account =
      starter_account_fixture() |> age(inactivity_reminded_at: DateTime.add(now, -2, :day))

    seen = DateTime.add(now, -60, :second)
    session_log_fixture(account: account, context: :portal, timestamp: seen)

    assert {:ok, 1} = Inactivity.rollup(now)
    updated = Repo.reload!(account)
    assert updated.last_active_at == seen
    assert is_nil(updated.inactivity_reminded_at)
    assert {:ok, 0} = Inactivity.rollup(now)
    assert Repo.reload!(account).last_active_at == seen
  end

  test "watermark catches activity after several missed daily runs" do
    now = DateTime.utc_now()

    Repo.query!("UPDATE account_activity_rollups SET processed_until=$1", [
      DateTime.add(now, -10, :day)
    ])

    account = starter_account_fixture() |> age()
    seen = DateTime.add(now, -5, :day)
    session_log_fixture(account: account, timestamp: seen)
    assert {:ok, 1} = Inactivity.rollup(now)
    assert Repo.reload!(account).last_active_at == seen
  end

  test "activity survives expired API credentials through the retained request log" do
    account = starter_account_fixture() |> age()
    seen = DateTime.add(DateTime.utc_now(), -60, :second)
    Portal.APIRequestLogFixtures.api_request_log_fixture(account: account, inserted_at: seen)
    assert {:ok, 1} = Inactivity.rollup()
    assert Repo.reload!(account).last_active_at == seen
  end

  test "an observation gap longer than retention restarts the clock instead of guessing inactivity" do
    now = DateTime.utc_now()

    account =
      starter_account_fixture() |> age(inactivity_reminded_at: DateTime.add(now, -15, :day))

    Repo.query!("UPDATE account_activity_rollups SET processed_until=$1", [
      DateTime.add(now, -122, :day)
    ])

    assert {:ok, 0} = Inactivity.rollup(now)
    updated = Repo.reload!(account)
    assert updated.last_active_at == now
    refute updated.inactivity_reminded_at
    assert {:ok, 0} = Inactivity.sweep(now)
    refute Repo.reload!(account).scheduled_deletion_at
  end

  test "the automatic sweep queues only year-old Starter accounts and delivery checks fresh activity" do
    old = starter_account_fixture() |> age()
    admin_actor_fixture(account: old)
    recent = starter_account_fixture()
    admin_actor_fixture(account: recent)
    paid = team_account_fixture() |> age()
    admin_actor_fixture(account: paid)
    assert {:ok, 1} = Inactivity.sweep()

    assert_enqueued(
      worker: AccountInactivityReminder,
      args: %{"account_id" => old.id, "reason" => "inactive"}
    )

    refute_enqueued(worker: AccountInactivityReminder, args: %{"account_id" => recent.id})
    refute_enqueued(worker: AccountInactivityReminder, args: %{"account_id" => paid.id})
    session_log_fixture(account: old)
    assert :ok = send_reminder(old)
    refute Repo.reload!(old).inactivity_reminded_at
  end

  test "suppressed and recipient-less accounts do not consume the automatic batch" do
    account = starter_account_fixture() |> age()
    admin = admin_actor_fixture(account: account)

    Repo.insert!(%Portal.EmailSuppression{
      email: Portal.EmailSuppression.normalize_email(admin.email)
    })

    starter_account_fixture() |> age()
    assert {:ok, 0} = Inactivity.sweep()
  end

  test "an online gateway keeps an account active even without a new connection log" do
    account = starter_account_fixture() |> age()

    Portal.Presence.track(
      self(),
      "presences:account_devices:" <> account.id,
      Ecto.UUID.generate(),
      %{}
    )

    assert {:ok, 1} = Inactivity.rollup()
    assert DateTime.diff(DateTime.utc_now(), Repo.reload!(account).last_active_at) < 5
  end

  test "preview excludes setup and sign-ins, but accepts automatically created defaults" do
    default = starter_account_fixture()
    admin = admin_actor_fixture(account: default)
    site_fixture(account: default, name: "Default Site")
    internet = internet_site_fixture(account: default)

    resource_fixture(
      account: default,
      site: internet,
      type: :internet,
      address: nil,
      name: "Internet"
    )

    owner =
      Repo.insert!(%Portal.Group{account_id: default.id, name: "Account owner", type: :static})

    Repo.insert!(%Portal.Group{account_id: default.id, name: "Everyone", type: :managed})

    pool =
      Repo.insert!(%Portal.Resource{
        account_id: default.id,
        type: :device_pool,
        name: "My devices",
        device_membership_criteria: Portal.Resource.DeviceMembershipCriteria.own_devices()
      })

    Repo.insert!(%Portal.Policy{account_id: default.id, group_id: owner.id, resource_id: pool.id})

    configured = starter_account_fixture()
    admin_actor_fixture(account: configured)
    resource_fixture(account: configured)
    used = starter_account_fixture()
    admin_actor_fixture(account: used)
    session_log_fixture(account: used)
    paid = team_account_fixture()
    admin_actor_fixture(account: paid)
    ids = preview_ids()
    assert default.id in ids
    refute configured.id in ids
    refute used.id in ids
    refute paid.id in ids
    assert admin.account_id == default.id
  end

  test "manual queue is capped at 100, and repeat calls skip pending reminders" do
    accounts =
      for _ <- 1..101 do
        account = starter_account_fixture()
        admin_actor_fixture(account: account)
        account
      end

    assert {:ok, 100} = Portal.Ops.remind_default_accounts()
    assert {:ok, 1} = Portal.Ops.remind_default_accounts()
    assert {:ok, 0} = Portal.Ops.remind_default_accounts()
    assert length(all_enqueued(worker: AccountInactivityReminder)) == length(accounts)
  end

  test "warning starts its grace period only after successful delivery and is idempotent" do
    acs_response()
    account = starter_account_fixture() |> age()
    admin_actor_fixture(account: account)
    assert :ok = send_reminder(account)
    assert Repo.reload!(account).inactivity_reminded_at
    assert :ok = send_reminder(account)
    assert Repo.aggregate(Portal.OutboundEmail, :count) == 1
    assert_received {:acs_request, %{"content" => %{"plainText" => body}}}
    assert body =~ "12 months"
    assert body =~ "two weeks"
    assert body =~ account.slug
  end

  test "manual default reminders do not require a 12-month-old activity baseline" do
    acs_response()
    account = starter_account_fixture()
    admin_actor_fixture(account: account)
    assert :ok = send_reminder(account, "default")
    assert Repo.reload!(account).inactivity_reminded_at
  end

  test "queued default reminders recheck setup at delivery" do
    acs_response()
    account = starter_account_fixture()
    admin_actor_fixture(account: account)
    resource_fixture(account: account)
    assert :ok = send_reminder(account, "default")
    refute Repo.reload!(account).inactivity_reminded_at
    refute_email_sent()
  end

  test "failed or suppressed emails never start the deletion clock" do
    acs_response(422)
    account = starter_account_fixture() |> age()
    admin = admin_actor_fixture(account: account)
    assert {:error, _} = send_reminder(account)
    refute Repo.reload!(account).inactivity_reminded_at

    Repo.insert!(%Portal.EmailSuppression{
      email: Portal.EmailSuppression.normalize_email(admin.email)
    })

    assert :ok = send_reminder(account)
    refute Repo.reload!(account).inactivity_reminded_at
  end

  test "fresh sign-in after the daily rollup cancels a warning before deletion" do
    now = DateTime.utc_now()

    account =
      starter_account_fixture() |> age(inactivity_reminded_at: DateTime.add(now, -15, :day))

    admin_actor_fixture(account: account)
    session_log_fixture(account: account, context: :portal)
    assert {:ok, 0} = Inactivity.sweep()
    updated = Repo.reload!(account)
    refute updated.inactivity_reminded_at
    refute updated.scheduled_deletion_at
    refute updated.is_disabled
  end

  test "two weeks after a reminder, the sweep schedules deletion using the existing grace period" do
    now = DateTime.utc_now()

    account =
      starter_account_fixture() |> age(inactivity_reminded_at: DateTime.add(now, -14, :day))

    admin_actor_fixture(account: account)
    assert {:ok, 0} = Inactivity.sweep(now)
    updated = Repo.reload!(account)
    assert updated.is_disabled
    assert updated.scheduled_deletion_at == DateTime.add(now, 7, :day)
    refute_enqueued(worker: Portal.Workers.DeleteAccount)
    assert {:ok, 0} = Inactivity.sweep(now)
  end

  test "manual default reminders also expire after two weeks despite the fresh migration baseline" do
    now = DateTime.utc_now()

    account =
      starter_account_fixture()
      |> change(inactivity_reminded_at: DateTime.add(now, -14, :day))
      |> Repo.update!()

    assert {:ok, 0} = Inactivity.sweep(now)
    assert Repo.reload!(account).scheduled_deletion_at
  end

  test "an open portal session at the deadline keeps the account" do
    account =
      starter_account_fixture()
      |> age(inactivity_reminded_at: DateTime.add(DateTime.utc_now(), -15, :day))

    admin = admin_actor_fixture(account: account)
    Portal.Presence.PortalSessions.track(admin.id, Ecto.UUID.generate())

    assert {:ok, 0} = Inactivity.sweep()
    updated = Repo.reload!(account)
    refute updated.inactivity_reminded_at
    refute updated.scheduled_deletion_at
  end

  test "upgrading a warned account prevents deletion and clears its warning" do
    account =
      team_account_fixture()
      |> age(inactivity_reminded_at: DateTime.add(DateTime.utc_now(), -15, :day))

    assert {:ok, 0} = Inactivity.sweep()
    refute Repo.reload!(account).inactivity_reminded_at
    refute Repo.reload!(account).scheduled_deletion_at
  end

  test "cancelling deletion restarts inactivity rather than immediately scheduling it again" do
    now = DateTime.utc_now()

    account =
      starter_account_fixture()
      |> age(
        inactivity_reminded_at: DateTime.add(now, -15, :day),
        scheduled_deletion_at: DateTime.add(now, 7, :day),
        is_disabled: true,
        disabled_reason: "Account inactivity"
      )

    actor = admin_actor_fixture(account: account)
    subject = Portal.SubjectFixtures.subject_fixture(account: account, actor: actor)
    assert {:ok, updated} = Portal.Accounts.Deletion.cancel_account_deletion(account, subject)
    refute updated.inactivity_reminded_at
    refute updated.disabled_reason
    assert DateTime.diff(now, updated.last_active_at) < 5
    assert {:ok, 0} = Inactivity.sweep()
    refute Repo.reload!(account).scheduled_deletion_at
  end

  test "stale activity rollup prevents destructive lifecycle transitions" do
    account =
      starter_account_fixture()
      |> age(inactivity_reminded_at: DateTime.add(DateTime.utc_now(), -15, :day))

    Repo.query!("UPDATE account_activity_rollups SET processed_until=$1", [
      DateTime.add(DateTime.utc_now(), -3, :day)
    ])

    assert {:error, :activity_rollup_stale} = Inactivity.sweep()
    refute Repo.reload!(account).scheduled_deletion_at
  end
end
