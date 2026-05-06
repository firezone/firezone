defmodule Portal.Workers.DeleteAccountTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.DeleteAccount

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.OutboundEmailTestHelpers

  describe "perform/1" do
    test "deletes the account and emails admins when deletion is due" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      admin = admin_actor_fixture(account: account)

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Deletion Complete"
      assert email.text_body =~ account.slug
      assert email.text_body =~ account.id
      assert Enum.map(email.bcc, fn {_name, address} -> address end) == [admin.email]
    end

    test "deletes the account without emailing when there are no admin actors" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
      assert collect_queued_emails(account.id) == []
    end

    test "does nothing when the account does not exist" do
      assert :ok = perform_job(DeleteAccount, %{"account_id" => Ecto.UUID.generate()})
    end

    test "does nothing when the account was unscheduled" do
      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: nil
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
      assert collect_queued_emails(account.id) == []
    end

    test "does nothing when the account is not disabled" do
      account =
        update_account(account_fixture(),
          disabled_at: nil,
          scheduled_deletion_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
      assert collect_queued_emails(account.id) == []
    end

    test "snoozes the job until the scheduled deletion time when deletion is not yet due" do
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert {:snooze, snooze_seconds} = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert snooze_seconds > 0
      assert fetch_account(account.id)
      assert collect_queued_emails(account.id) == []
    end
  end
end
