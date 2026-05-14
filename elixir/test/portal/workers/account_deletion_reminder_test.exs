defmodule Portal.Workers.AccountDeletionReminderTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.AccountDeletionReminder

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers

  describe "perform/1" do
    test "sends reminder email to admins when account is scheduled for deletion" do
      scheduled_deletion_at =
        DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: scheduled_deletion_at
        )

      admin = admin_actor_fixture(account: account)

      assert :ok = perform_job(AccountDeletionReminder, %{"account_id" => account.id})

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Deletion Reminder"
      assert email.text_body =~ account.slug
      assert email.text_body =~ account.id
      assert email.text_body =~ Calendar.strftime(scheduled_deletion_at, "%B %-d, %Y")
      assert email.text_body =~ "/#{account.slug}/settings/account"
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [admin.email]
    end

    test "does nothing when the account does not exist" do
      assert :ok = perform_job(AccountDeletionReminder, %{"account_id" => Ecto.UUID.generate()})
    end

    test "does nothing when deletion was cancelled" do
      account = update_account(account_fixture(), scheduled_deletion_at: nil)

      assert :ok = perform_job(AccountDeletionReminder, %{"account_id" => account.id})
      assert collect_queued_emails(account.id) == []
    end

    test "does nothing when there are no admin actors" do
      scheduled_deletion_at =
        DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(AccountDeletionReminder, %{"account_id" => account.id})
      assert collect_queued_emails(account.id) == []
    end
  end
end
