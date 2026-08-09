defmodule Portal.Crl.SchedulerTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.DeviceTrustFixtures

  alias Portal.Crl.Scheduler
  alias Portal.Crypto.X509

  setup do
    %{account: account_fixture(), pki: pki()}
  end

  describe "perform/1" do
    test "queues a job per issuer whose list is due", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}

      assert [job] = all_sync_jobs()
      assert job.args["account_id"] == account.id
      assert Base.decode64!(job.args["issuer"]) == endpoint.issuer
      assert job.args["distribution_point"] == endpoint.distribution_point
    end

    test "skips an issuer whose cached list is not due yet", %{account: account, pki: pki} do
      not_due = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
      endpoint_fixture(account, pki.ca_der, crl_next_update: not_due)

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert all_sync_jobs() == []
    end

    test "skips an issuer with no CRL address", %{account: account, pki: pki} do
      endpoint_fixture(account, pki.ca_der, crl_urls: [])

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert all_sync_jobs() == []
    end

    test "skips a disabled account", %{account: account, pki: pki} do
      endpoint_fixture(account, pki.ca_der)
      Repo.update_all(Portal.Account, set: [is_disabled: true])

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert all_sync_jobs() == []
    end
  end

  defp all_sync_jobs do
    Repo.all(Oban.Job) |> Enum.filter(&(&1.worker == "Portal.Crl.Sync"))
  end

  defp endpoint_fixture(account, issuer_der, attrs \\ []) do
    issuer = X509.subject(issuer_der)
    crl_urls = Keyword.get(attrs, :crl_urls, ["http://crl.example.test/ca.crl"])

    Repo.insert!(%Portal.RevocationEndpoint{
      account_id: account.id,
      issuer: issuer,
      distribution_point: List.first(crl_urls) || "http://crl.example.test/ca.crl",
      crl_urls: crl_urls,
      crl_next_update: Keyword.get(attrs, :crl_next_update),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end
end
