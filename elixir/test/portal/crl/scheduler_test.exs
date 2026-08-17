defmodule Portal.Crl.SchedulerTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.DeviceTrustFixtures
  import Portal.FeaturesFixtures

  alias Portal.Crl.Scheduler
  alias Portal.Crypto.X509

  setup do
    enable_feature(:trust_anchors)
    %{account: account_fixture(), pki: pki()}
  end

  describe "perform/1 when the trust_anchors feature is off" do
    test "nothing is queued, so endpoints are left exactly as they are", %{
      account: account,
      pki: pki
    } do
      endpoint_fixture(account, pki.ca_der)
      Portal.Repo.delete_all(Portal.Features)

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :skipped}

      assert all_sync_jobs() == []
    end
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

    test "queues an issuer whose delta is due while its list is not", %{
      account: account,
      pki: pki
    } do
      # A CA that reissues its list weekly while replacing the delta daily would
      # otherwise have a week of revocations wait on the list's own schedule.
      endpoint_fixture(account, pki.ca_der,
        crl_next_update: in_days(7),
        delta_next_update: in_days(-1)
      )

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert [_job] = all_sync_jobs()
    end

    test "queues an issuer whose last delta check failed", %{account: account, pki: pki} do
      endpoint_fixture(account, pki.ca_der, crl_next_update: in_days(7), delta_error: "boom")

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert [_job] = all_sync_jobs()
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
      delta_next_update: Keyword.get(attrs, :delta_next_update),
      delta_error: Keyword.get(attrs, :delta_error),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp in_days(days) do
    DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
  end
end
