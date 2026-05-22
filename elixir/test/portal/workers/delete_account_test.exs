defmodule Portal.Workers.DeleteAccountTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.DeleteAccount
  alias Portal.Workers.AccountDeletionCompleted
  alias Portal.Workers.DeleteSubscription

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  describe "perform/1" do
    test "deletes account and enqueues AccountDeletionCompleted job with admin emails" do
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

      assert_enqueued(
        worker: AccountDeletionCompleted,
        args: %{
          "account_id" => account.id,
          "account_slug" => account.slug,
          "admin_emails" => [admin.email]
        }
      )
    end

    test "deletes account without enqueuing completion job when there are no admin actors" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil
      refute_enqueued(worker: AccountDeletionCompleted)
    end

    test "is a no-op when account already deleted (RETURNING returns 0 rows)" do
      assert :ok = perform_job(DeleteAccount, %{"account_id" => Ecto.UUID.generate()})
    end

    test "is a no-op when account conditions cleared (scheduled_deletion_at nil)" do
      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: nil
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
      refute_enqueued(worker: AccountDeletionCompleted)
    end

    test "is a no-op when account conditions cleared (disabled_at nil)" do
      account =
        update_account(account_fixture(),
          disabled_at: nil,
          scheduled_deletion_at:
            DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id)
      refute_enqueued(worker: AccountDeletionCompleted)
    end

    test "schedules DeleteSubscription job when customer_id present" do
      customer_id = "cus_#{System.unique_integer([:positive])}"
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at,
          metadata: %{stripe: %{customer_id: customer_id}}
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil

      assert_enqueued(worker: DeleteSubscription, args: %{"customer_id" => customer_id})
    end

    test "skips DeleteSubscription job when no customer_id" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(DeleteAccount, %{"account_id" => account.id})
      assert fetch_account(account.id) == nil

      refute_enqueued(worker: DeleteSubscription)
    end
  end
end
