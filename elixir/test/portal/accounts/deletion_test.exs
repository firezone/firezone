defmodule Portal.Accounts.DeletionTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Accounts.Deletion

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ObanJobFixtures
  import Portal.SubjectFixtures

  describe "schedule_account_deletion/3" do
    test "enqueues reminder job when deletion is more than 48 hours away" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)
      attrs = %{disabled_at: disabled_at, scheduled_deletion_at: scheduled_deletion_at}

      assert {:ok, _account} = Deletion.schedule_account_deletion(account, attrs, subject)

      refute_enqueued(worker: Portal.Workers.DeleteAccount)

      assert length(
               jobs_for_worker_and_arg(
                 "Portal.Workers.AccountDeletionReminder",
                 "account_id",
                 account.id
               )
             ) == 1
    end

    test "does not enqueue reminder when deletion is less than 48 hours away" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 1, :hour)
      attrs = %{disabled_at: disabled_at, scheduled_deletion_at: scheduled_deletion_at}

      assert {:ok, _account} = Deletion.schedule_account_deletion(account, attrs, subject)

      refute_enqueued(worker: Portal.Workers.DeleteAccount)

      assert jobs_for_worker_and_arg(
               "Portal.Workers.AccountDeletionReminder",
               "account_id",
               account.id
             ) == []
    end
  end

  describe "cancel_account_deletion/3" do
    test "cancels both delete and reminder jobs" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      disabled_at = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(disabled_at, 7, :day)
      reminder_at = DateTime.add(scheduled_deletion_at, -48, :hour)

      account =
        update_account(account,
          disabled_at: disabled_at,
          scheduled_deletion_at: scheduled_deletion_at
        )

      assert {:ok, _job} =
               Oban.insert(
                 Portal.Workers.DeleteAccount.new(%{"account_id" => account.id},
                   scheduled_at: scheduled_deletion_at
                 )
               )

      assert {:ok, _job} =
               Oban.insert(
                 Portal.Workers.AccountDeletionReminder.new(%{"account_id" => account.id},
                   scheduled_at: reminder_at
                 )
               )

      assert {:ok, _account} = Deletion.cancel_account_deletion(account, subject)

      [delete_job] =
        jobs_for_worker_and_arg("Portal.Workers.DeleteAccount", "account_id", account.id)

      [reminder_job] =
        jobs_for_worker_and_arg(
          "Portal.Workers.AccountDeletionReminder",
          "account_id",
          account.id
        )

      assert delete_job.state == "cancelled"
      assert reminder_job.state == "cancelled"
    end
  end
end
