defmodule Portal.Workers.DeleteOldSessionLogsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.SessionLogFixtures

  alias Portal.SessionLog
  alias Portal.Workers.DeleteOldSessionLogs

  describe "perform/1" do
    test "deletes session_logs older than 90 days" do
      old = session_log_fixture(timestamp: DateTime.utc_now() |> DateTime.add(-91, :day))

      assert :ok = perform_job(DeleteOldSessionLogs, %{})

      refute Repo.one(from sl in SessionLog, where: sl.log_id == ^old.log_id)
    end

    test "does not delete session_logs newer than 90 days" do
      recent = session_log_fixture(timestamp: DateTime.utc_now() |> DateTime.add(-89, :day))

      assert :ok = perform_job(DeleteOldSessionLogs, %{})

      assert Repo.one(from sl in SessionLog, where: sl.log_id == ^recent.log_id)
    end

    test "deletes old session_logs across accounts" do
      account1 = account_fixture()
      account2 = account_fixture()

      hundred_days_ago = DateTime.utc_now() |> DateTime.add(-100, :day)
      old1 = session_log_fixture(account: account1, timestamp: hundred_days_ago)
      old2 = session_log_fixture(account: account2, timestamp: hundred_days_ago)
      recent = session_log_fixture(account: account1)

      assert :ok = perform_job(DeleteOldSessionLogs, %{})

      refute Repo.one(from sl in SessionLog, where: sl.log_id == ^old1.log_id)
      refute Repo.one(from sl in SessionLog, where: sl.log_id == ^old2.log_id)
      assert Repo.one(from sl in SessionLog, where: sl.log_id == ^recent.log_id)
    end
  end
end
