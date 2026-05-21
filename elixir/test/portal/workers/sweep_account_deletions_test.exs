defmodule Portal.Workers.SweepAccountDeletionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Workers.SweepAccountDeletions
  alias Portal.Workers.DeleteAccount

  import Portal.AccountFixtures

  describe "perform/1" do
    test "enqueues DeleteAccount jobs for accounts due for deletion" do
      disabled_at = DateTime.utc_now() |> DateTime.add(-8, :day) |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)

      account =
        update_account(account_fixture(),
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert :ok = perform_job(SweepAccountDeletions, %{})

      assert_enqueued(worker: DeleteAccount, args: %{"account_id" => account.id})
    end

    test "skips accounts not yet due (scheduled_deletion_at in future)" do
      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
        )

      assert :ok = perform_job(SweepAccountDeletions, %{})

      refute_enqueued(worker: DeleteAccount, args: %{"account_id" => account.id})
    end

    test "skips accounts not disabled (disabled_at is nil)" do
      account =
        update_account(account_fixture(),
          disabled_at: nil,
          scheduled_deletion_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        )

      assert :ok = perform_job(SweepAccountDeletions, %{})

      refute_enqueued(worker: DeleteAccount, args: %{"account_id" => account.id})
    end

    test "skips accounts with no scheduled_deletion_at" do
      account =
        update_account(account_fixture(),
          disabled_at: DateTime.utc_now() |> DateTime.truncate(:second),
          scheduled_deletion_at: nil
        )

      assert :ok = perform_job(SweepAccountDeletions, %{})

      refute_enqueued(worker: DeleteAccount, args: %{"account_id" => account.id})
    end

    test "handles empty result (no accounts due)" do
      assert :ok = perform_job(SweepAccountDeletions, %{})
    end
  end
end
