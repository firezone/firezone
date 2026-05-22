defmodule Portal.Workers.AccountDeletionCompletedTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.AccountDeletionCompleted

  import Portal.AccountFixtures
  import Portal.OutboundEmailTestHelpers

  describe "perform/1" do
    test "queues completion email to admin emails" do
      account = account_fixture()
      admin_email = "admin@example.com"

      args = %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "admin_emails" => [admin_email]
      }

      assert :ok = perform_job(AccountDeletionCompleted, args)

      [email] = collect_queued_emails(account.id)
      assert email.subject == "Firezone Account Deletion Complete"
    end

    test "does nothing when admin_emails is empty" do
      account = account_fixture()

      args = %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "admin_emails" => []
      }

      assert :ok = perform_job(AccountDeletionCompleted, args)
      assert collect_queued_emails(account.id) == []
    end
  end
end
