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

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(now, 7, :day)
      attrs = %{is_disabled: true, scheduled_deletion_at: scheduled_deletion_at}

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

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(now, 1, :hour)
      attrs = %{is_disabled: true, scheduled_deletion_at: scheduled_deletion_at}

      assert {:ok, _account} = Deletion.schedule_account_deletion(account, attrs, subject)

      refute_enqueued(worker: Portal.Workers.DeleteAccount)

      assert jobs_for_worker_and_arg(
               "Portal.Workers.AccountDeletionReminder",
               "account_id",
               account.id
             ) == []
    end
  end

  describe "save_deletion_feedback/3" do
    test "stores the feedback in the account metadata" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      assert {:ok, account} =
               Deletion.save_deletion_feedback(account, "Too hard to set up", subject)

      assert account.metadata.deletion_feedback == "Too hard to set up"
      assert fetch_account!(account.id).metadata.deletion_feedback == "Too hard to set up"
    end

    test "keeps the other metadata fields" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      account =
        update_account(account, %{
          metadata: %{marketing_attribution: %{"source" => "github"}}
        })

      assert {:ok, account} = Deletion.save_deletion_feedback(account, "Bye", subject)

      assert account.metadata.marketing_attribution == %{"source" => "github"}
      assert account.metadata.deletion_feedback == "Bye"
    end

    test "rejects feedback longer than 2000 characters" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      feedback = String.duplicate("a", 2001)

      assert {:error, changeset} = Deletion.save_deletion_feedback(account, feedback, subject)

      assert %{metadata: %{deletion_feedback: ["should be at most 2000 character(s)"]}} =
               errors_on(changeset)

      refute fetch_account!(account.id).metadata.deletion_feedback
    end

    test "rejects a subject from another account" do
      account = account_fixture()
      other_account = account_fixture()
      actor = admin_actor_fixture(account: other_account)
      subject = subject_fixture(account: other_account, actor: actor)

      assert {:error, _reason} = Deletion.save_deletion_feedback(account, "Bye", subject)

      refute fetch_account!(account.id).metadata.deletion_feedback
    end
  end

  describe "cancel_account_deletion/3" do
    test "cancels both delete and reminder jobs" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      scheduled_deletion_at = DateTime.add(now, 7, :day)
      reminder_at = DateTime.add(scheduled_deletion_at, -48, :hour)

      account =
        update_account(account,
          is_disabled: true,
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
