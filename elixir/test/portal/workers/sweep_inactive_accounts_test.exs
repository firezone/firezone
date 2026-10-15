defmodule Portal.Workers.SweepInactiveAccountsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.AccountActivityRollup
  alias Portal.Workers.AccountDeletionReminder
  alias Portal.Workers.AccountInactivityReminder
  alias Portal.Workers.SweepInactiveAccounts

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers
  import Portal.SessionLogFixtures

  defp inactive_account_fixture(attrs \\ []) do
    last_active_at = DateTime.add(DateTime.utc_now(), -400, :day)
    update_account(starter_account_fixture(), Keyword.put_new(attrs, :last_active_at, last_active_at))
  end

  defp reminded_account_fixture(days_ago, attrs \\ []) do
    reminded_at = DateTime.add(DateTime.utc_now(), -days_ago, :day)
    inactive_account_fixture(Keyword.put(attrs, :inactivity_reminded_at, reminded_at))
  end

  describe "perform/1" do
    test "queues reminders only for Starter accounts inactive for a year" do
      inactive = inactive_account_fixture()
      admin_actor_fixture(account: inactive)
      recent = starter_account_fixture()
      admin_actor_fixture(account: recent)
      paid = update_account(team_account_fixture(), last_active_at: inactive.last_active_at)
      admin_actor_fixture(account: paid)

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      assert_enqueued(
        worker: AccountInactivityReminder,
        args: %{"account_id" => inactive.id, "reason" => "inactive"}
      )

      refute_enqueued(worker: AccountInactivityReminder, args: %{"account_id" => recent.id})
      refute_enqueued(worker: AccountInactivityReminder, args: %{"account_id" => paid.id})
    end

    test "skips accounts whose admins cannot receive email" do
      suppressed = inactive_account_fixture()
      admin = admin_actor_fixture(account: suppressed)

      Repo.insert!(%Portal.EmailSuppression{
        email: Portal.EmailSuppression.normalize_email(admin.email)
      })

      without_admins = inactive_account_fixture()

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      refute_enqueued(worker: AccountInactivityReminder, args: %{"account_id" => suppressed.id})

      refute_enqueued(
        worker: AccountInactivityReminder,
        args: %{"account_id" => without_admins.id}
      )
    end

    test "disables and schedules deletion two weeks after the reminder" do
      account = reminded_account_fixture(14)
      admin = admin_actor_fixture(account: account)

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      account = Repo.reload!(account)
      assert account.is_disabled
      assert account.disabled_reason == "Account inactivity"

      assert_in_delta DateTime.diff(account.scheduled_deletion_at, DateTime.utc_now(), :day),
                      7,
                      1

      assert_enqueued(worker: AccountDeletionReminder, args: %{"account_id" => account.id})
      refute_enqueued(worker: Portal.Workers.DeleteAccount)

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Scheduled for Deletion"
      assert email.text_body =~ "/#{account.slug}/settings/account"
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [admin.email]

      assert :ok = perform_job(SweepInactiveAccounts, %{})
      assert length(collect_queued_emails(account.id)) == 1
    end

    test "schedules deletion after a default reminder despite recent activity before it" do
      account =
        update_account(starter_account_fixture(),
          inactivity_reminded_at: DateTime.add(DateTime.utc_now(), -14, :day)
        )

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      assert Repo.reload!(account).scheduled_deletion_at
    end

    test "keeps an account with activity after the reminder" do
      account = reminded_account_fixture(15)
      admin_actor_fixture(account: account)
      session_log_fixture(account: account, context: :portal)

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      account = Repo.reload!(account)
      assert is_nil(account.inactivity_reminded_at)
      assert is_nil(account.scheduled_deletion_at)
      refute account.is_disabled
    end

    test "keeps an account with an open portal session" do
      account = reminded_account_fixture(15)
      admin = admin_actor_fixture(account: account)
      Portal.Presence.PortalSessions.track(admin.id, Ecto.UUID.generate())

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      account = Repo.reload!(account)
      assert is_nil(account.inactivity_reminded_at)
      assert is_nil(account.scheduled_deletion_at)
    end

    test "keeps an account whose reminder is less than two weeks old" do
      account = reminded_account_fixture(13)

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      account = Repo.reload!(account)
      assert account.inactivity_reminded_at
      assert is_nil(account.scheduled_deletion_at)
    end

    test "clears the reminder of an upgraded account" do
      account =
        update_account(team_account_fixture(),
          last_active_at: DateTime.add(DateTime.utc_now(), -400, :day),
          inactivity_reminded_at: DateTime.add(DateTime.utc_now(), -15, :day)
        )

      assert :ok = perform_job(SweepInactiveAccounts, %{})

      account = Repo.reload!(account)
      assert is_nil(account.inactivity_reminded_at)
      assert is_nil(account.scheduled_deletion_at)
    end

    test "does nothing while the activity rollup is stale" do
      account = reminded_account_fixture(15)

      Repo.update_all(AccountActivityRollup,
        set: [processed_until: DateTime.add(DateTime.utc_now(), -3, :day)]
      )

      assert {:error, :activity_rollup_stale} = perform_job(SweepInactiveAccounts, %{})

      assert is_nil(Repo.reload!(account).scheduled_deletion_at)
    end
  end
end
