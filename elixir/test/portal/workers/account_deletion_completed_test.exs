defmodule Portal.Workers.AccountDeletionCompletedTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo
  import Swoosh.TestAssertions

  alias Portal.Workers.AccountDeletionCompleted

  import Portal.AccountFixtures

  describe "perform/1" do
    test "sends completion email to admin emails" do
      account = account_fixture()
      admin_email = "admin@example.com"

      args = %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "admin_emails" => [admin_email]
      }

      assert :ok = perform_job(AccountDeletionCompleted, args)

      assert_email_sent(subject: "Firezone Account Deletion Complete")
    end

    test "does nothing when admin_emails is empty" do
      account = account_fixture()

      args = %{
        "account_id" => account.id,
        "account_slug" => account.slug,
        "admin_emails" => []
      }

      assert :ok = perform_job(AccountDeletionCompleted, args)
    end
  end
end
