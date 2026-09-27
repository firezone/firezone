defmodule Portal.Workers.DeleteOldSessionLogsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.SessionLogFixtures

  alias Portal.SessionLog
  alias Portal.Workers.DeleteOldSessionLogs

  describe "perform/1" do
    test "deletes session_logs older than 121 days" do
      old = session_log_fixture(timestamp: DateTime.utc_now() |> DateTime.add(-122, :day))

      assert :ok = perform_job(DeleteOldSessionLogs, %{})

      refute Repo.one(from sl in SessionLog, where: sl.log_id == ^old.log_id)
    end

    test "does not delete session_logs newer than 121 days" do
      recent = session_log_fixture(timestamp: DateTime.utc_now() |> DateTime.add(-120, :day))
      Repo.query!("SET LOCAL timezone = 'Pacific/Honolulu'")
      boundary = DateTime.new!(Date.add(Date.utc_today(), -121), ~T[00:00:00.000000], "Etc/UTC")
      retained = session_log_fixture(timestamp: boundary)

      assert :ok = perform_job(DeleteOldSessionLogs, %{})

      assert Repo.one(from sl in SessionLog, where: sl.log_id == ^recent.log_id)
      assert Repo.one(from sl in SessionLog, where: sl.log_id == ^retained.log_id)
    end

    test "deletes old session_logs across accounts" do
      account1 = account_fixture()
      account2 = account_fixture()

      expired_at = DateTime.utc_now() |> DateTime.add(-130, :day)
      old1 = session_log_fixture(account: account1, timestamp: expired_at)
      old2 = session_log_fixture(account: account2, timestamp: expired_at)
      recent = session_log_fixture(account: account1)

      assert :ok = perform_job(DeleteOldSessionLogs, %{})

      refute Repo.one(from sl in SessionLog, where: sl.log_id == ^old1.log_id)
      refute Repo.one(from sl in SessionLog, where: sl.log_id == ^old2.log_id)
      assert Repo.one(from sl in SessionLog, where: sl.log_id == ^recent.log_id)
    end
  end
end
