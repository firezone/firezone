defmodule Portal.Workers.DeleteAccountTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.DeleteAccount

  import Portal.AccountFixtures

  describe "perform/1" do
    test "deletes the account when deletion is due" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
    end

    test "does nothing when the account was unscheduled" do
      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: nil
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
    end

    test "does nothing when the account is not disabled" do
      account =
        update_account(account_fixture(),
          disabled_at: nil,
          scheduled_deletion_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
    end

    test "does nothing when the scheduled deletion time is still in the future" do
      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
    end
  end
end
