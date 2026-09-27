defmodule Portal.Workers.DeleteOldAPIRequestLogsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.APIRequestLogFixtures

  alias Portal.APIRequestLog
  alias Portal.Workers.DeleteOldAPIRequestLogs

  describe "perform/1" do
    test "deletes api_request_logs older than 121 days" do
      old = api_request_log_fixture(inserted_at: DateTime.utc_now() |> DateTime.add(-122, :day))

      assert :ok = perform_job(DeleteOldAPIRequestLogs, %{})

      refute Repo.one(from arl in APIRequestLog, where: arl.log_id == ^old.log_id)
    end

    test "does not delete api_request_logs newer than 121 days" do
      recent =
        api_request_log_fixture(inserted_at: DateTime.utc_now() |> DateTime.add(-120, :day))
      Repo.query!("SET LOCAL timezone = 'Pacific/Honolulu'")
      boundary = DateTime.new!(Date.add(Date.utc_today(), -121), ~T[00:00:00.000000], "Etc/UTC")
      retained = api_request_log_fixture(inserted_at: boundary)

      assert :ok = perform_job(DeleteOldAPIRequestLogs, %{})

      assert Repo.one(from arl in APIRequestLog, where: arl.log_id == ^recent.log_id)
      assert Repo.one(from arl in APIRequestLog, where: arl.log_id == ^retained.log_id)
    end

    test "deletes old api_request_logs across accounts" do
      account1 = account_fixture()
      account2 = account_fixture()

      expired_at = DateTime.utc_now() |> DateTime.add(-130, :day)
      old1 = api_request_log_fixture(account: account1, inserted_at: expired_at)
      old2 = api_request_log_fixture(account: account2, inserted_at: expired_at)
      recent = api_request_log_fixture(account: account1)

      assert :ok = perform_job(DeleteOldAPIRequestLogs, %{})

      refute Repo.one(from arl in APIRequestLog, where: arl.log_id == ^old1.log_id)
      refute Repo.one(from arl in APIRequestLog, where: arl.log_id == ^old2.log_id)
      assert Repo.one(from arl in APIRequestLog, where: arl.log_id == ^recent.log_id)
    end
  end
end
