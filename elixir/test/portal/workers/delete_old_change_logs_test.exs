defmodule Portal.Workers.DeleteOldChangeLogsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.ChangeLogFixtures

  alias Portal.ChangeLog
  alias Portal.Workers.DeleteOldChangeLogs

  describe "perform/1" do
    test "deletes change_logs older than 121 days" do
      old = change_log_fixture(timestamp: DateTime.utc_now() |> DateTime.add(-122, :day))

      assert :ok = perform_job(DeleteOldChangeLogs, %{})

      refute Repo.one(from cl in ChangeLog, where: cl.lsn == ^old.lsn)
    end

    test "does not delete change_logs newer than 121 days" do
      recent = change_log_fixture(timestamp: DateTime.utc_now() |> DateTime.add(-120, :day))
      Repo.query!("SET LOCAL timezone = 'Pacific/Honolulu'")
      boundary = DateTime.new!(Date.add(Date.utc_today(), -121), ~T[00:00:00.000000], "Etc/UTC")
      retained = change_log_fixture(timestamp: boundary)

      assert :ok = perform_job(DeleteOldChangeLogs, %{})

      assert Repo.one(from cl in ChangeLog, where: cl.lsn == ^recent.lsn)
      assert Repo.one(from cl in ChangeLog, where: cl.lsn == ^retained.lsn)
    end

    test "deletes old change_logs across accounts" do
      account1 = account_fixture()
      account2 = account_fixture()

      expired_at = DateTime.utc_now() |> DateTime.add(-130, :day)
      old1 = change_log_fixture(account: account1, timestamp: expired_at)
      old2 = change_log_fixture(account: account2, timestamp: expired_at)
      recent = change_log_fixture(account: account1)

      assert :ok = perform_job(DeleteOldChangeLogs, %{})

      refute Repo.one(from cl in ChangeLog, where: cl.lsn == ^old1.lsn)
      refute Repo.one(from cl in ChangeLog, where: cl.lsn == ^old2.lsn)
      assert Repo.one(from cl in ChangeLog, where: cl.lsn == ^recent.lsn)
    end
  end
end
