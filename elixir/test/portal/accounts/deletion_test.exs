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

  describe "cancel_account_deletion/2" do
    test "restarts the inactivity period of an account scheduled for deletion" do
      now = DateTime.utc_now()

      account =
        update_account(starter_account_fixture(),
          is_disabled: true,
          disabled_reason: "Account inactivity",
          scheduled_deletion_at: DateTime.add(now, 7, :day),
          last_active_at: DateTime.add(now, -400, :day),
          inactivity_reminded_at: DateTime.add(now, -15, :day)
        )

      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      assert {:ok, account} = Deletion.cancel_account_deletion(account, subject)

      refute account.is_disabled
      assert is_nil(account.disabled_reason)
      assert is_nil(account.inactivity_reminded_at)
      assert DateTime.diff(DateTime.utc_now(), account.last_active_at) < 5
    end
  end

  describe "send_deletion_feedback/3" do
    setup do
      Portal.Config.put_env_override(:portal, Portal.Mailer.FeedbackEmail, recipient: "feedback@example.com")
      :ok
    end

    test "sends nothing when the feedback recipient is not configured" do
      Portal.Config.put_env_override(:portal, Portal.Mailer.FeedbackEmail, recipient: nil)
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      assert :ok = Deletion.send_deletion_feedback(account, "Bye", subject)

      assert [] == all_enqueued(worker: Portal.Workers.OutboundEmail)
    end

    test "enqueues the feedback to the feedback recipient" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      assert :ok = Deletion.send_deletion_feedback(account, "Too hard to set up", subject)

      assert [job] = all_enqueued(worker: Portal.Workers.OutboundEmail)
      assert job.args["account_id"] == account.id
      assert %{"to" => [%{"address" => "feedback@example.com"}]} = job.args["request"]
      assert job.args["request"]["text_body"] =~ "Too hard to set up"
    end

    test "truncates feedback longer than the maximum length" do
      account = account_fixture()
      actor = admin_actor_fixture(account: account)
      subject = subject_fixture(account: account, actor: actor)

      feedback = String.duplicate("a", Deletion.feedback_max_length() + 1)

      assert :ok = Deletion.send_deletion_feedback(account, feedback, subject)

      assert [job] = all_enqueued(worker: Portal.Workers.OutboundEmail)
      refute job.args["request"]["text_body"] =~ feedback
    end

    test "rejects a subject from another account" do
      account = account_fixture()
      other_account = account_fixture()
      actor = admin_actor_fixture(account: other_account)
      subject = subject_fixture(account: other_account, actor: actor)

      assert {:error, :unauthorized} = Deletion.send_deletion_feedback(account, "Bye", subject)

      assert [] == all_enqueued(worker: Portal.Workers.OutboundEmail)
    end
  end
end
