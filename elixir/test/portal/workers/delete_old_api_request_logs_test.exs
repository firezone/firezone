defmodule Portal.Workers.DeleteOldAPIRequestLogsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.APIRequestLogFixtures

  alias Portal.APIRequestLog
  alias Portal.Workers.DeleteOldAPIRequestLogs

  describe "perform/1" do
    test "deletes api_request_logs older than 90 days" do
      old = api_request_log_fixture(inserted_at: DateTime.utc_now() |> DateTime.add(-91, :day))

      assert :ok = perform_job(DeleteOldAPIRequestLogs, %{})

      refute Repo.one(from arl in APIRequestLog, where: arl.event_id == ^old.event_id)
    end

    test "does not delete api_request_logs newer than 90 days" do
      recent =
        api_request_log_fixture(inserted_at: DateTime.utc_now() |> DateTime.add(-89, :day))

      assert :ok = perform_job(DeleteOldAPIRequestLogs, %{})

      assert Repo.one(from arl in APIRequestLog, where: arl.event_id == ^recent.event_id)
    end

    test "deletes old api_request_logs across accounts" do
      account1 = account_fixture()
      account2 = account_fixture()

      hundred_days_ago = DateTime.utc_now() |> DateTime.add(-100, :day)
      old1 = api_request_log_fixture(account: account1, inserted_at: hundred_days_ago)
      old2 = api_request_log_fixture(account: account2, inserted_at: hundred_days_ago)
      recent = api_request_log_fixture(account: account1)

      assert :ok = perform_job(DeleteOldAPIRequestLogs, %{})

      refute Repo.one(from arl in APIRequestLog, where: arl.event_id == ^old1.event_id)
      refute Repo.one(from arl in APIRequestLog, where: arl.event_id == ^old2.event_id)
      assert Repo.one(from arl in APIRequestLog, where: arl.event_id == ^recent.event_id)
    end
  end
end
