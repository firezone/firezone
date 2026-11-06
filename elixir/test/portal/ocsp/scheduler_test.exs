defmodule Portal.Ocsp.SchedulerTest do
  use Portal.DataCase, async: true

  import Portal.RevocationFixtures
  import Portal.AccountFixtures
  import Portal.DeviceTrustFixtures

  alias Portal.Ocsp.Scheduler

  setup do
    %{account: account_fixture(), pki: pki()}
  end

  describe "perform/1" do
    test "queues an issuer that publishes no list", %{account: account, pki: pki} do
      endpoint = ocsp_endpoint_fixture(account: account, issuer_der: pki.ca_der)

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}

      assert [job] = all_sync_jobs()
      assert job.args["account_id"] == account.id
      assert Base.decode64!(job.args["issuer"]) == endpoint.issuer
      assert job.args["distribution_point"] == endpoint.distribution_point
    end

    test "skips an issuer whose list is current", %{account: account, pki: pki} do
      list_with_responder(account, pki, crl_next_update: in_days(1))

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert all_sync_jobs() == []
    end

    for {name, fields} <- [
          turned_off: [crl_is_disabled: true, crl_next_update: {:days, 1}],
          never_fetched: [crl_next_update: nil],
          expired: [crl_next_update: {:days, -1}]
        ] do
      test "queues an issuer whose list is #{name}", %{account: account, pki: pki} do
        fields =
          Enum.map(unquote(fields), fn
            {key, {:days, days}} -> {key, in_days(days)}
            field -> field
          end)

        list_with_responder(account, pki, fields)

        assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
        assert [_job] = all_sync_jobs()
      end
    end

    test "queues an issuer when any one of its lists has expired", %{account: account, pki: pki} do
      list_with_responder(account, pki, crl_next_update: in_days(1))

      revocation_endpoint_fixture(
        account: account,
        issuer_der: pki.ca_der,
        crl_urls: ["http://crl.example.test/b.crl"],
        crl_next_update: in_days(-1)
      )

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert [_job] = all_sync_jobs()
    end

    test "queues an issuer whose list's delta has expired", %{account: account, pki: pki} do
      list_with_responder(account, pki,
        crl_next_update: in_days(7),
        delta_fetched_at: DateTime.utc_now(),
        delta_next_update: in_days(-1)
      )

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert [_job] = all_sync_jobs()
    end

    test "skips a responder that was turned off", %{account: account, pki: pki} do
      ocsp_endpoint_fixture(account: account, issuer_der: pki.ca_der, ocsp_is_disabled: true)

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert all_sync_jobs() == []
    end

    test "skips a disabled account", %{account: account, pki: pki} do
      ocsp_endpoint_fixture(account: account, issuer_der: pki.ca_der)
      Repo.update_all(Portal.Account, set: [is_disabled: true])

      assert Scheduler.perform(%Oban.Job{}) == {:ok, :scheduled}
      assert all_sync_jobs() == []
    end
  end

  defp list_with_responder(account, pki, fields) do
    revocation_endpoint_fixture(
      [account: account, issuer_der: pki.ca_der, ocsp_urls: ["http://ocsp.example.test"]] ++
        fields
    )
  end

  defp all_sync_jobs do
    Repo.all(Oban.Job) |> Enum.filter(&(&1.worker == "Portal.Ocsp.Sync"))
  end

  defp in_days(days) do
    DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
  end
end
