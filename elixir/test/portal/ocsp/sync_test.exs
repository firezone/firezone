defmodule Portal.Ocsp.SyncTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures
  import Portal.DeviceTrustFixtures
  import ExUnit.CaptureLog

  alias Portal.Ocsp.Sync
  alias Portal.Crypto.X509

  @ocsp_url "http://ocsp.example.test"

  setup do
    account = account_fixture()
    enable_feature(:trust_anchors)
    pki = pki()
    trust_anchor_fixture(account: account, certs: [pki.ca_der])

    %{account: account, pki: pki}
  end

  describe "perform/1" do
    test "caches a good answer", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub(ocsp_response(pki.ca, leaf, status: :good))

      assert perform(endpoint) == {:ok, :refreshed}

      assert [status] = Repo.all(Portal.OcspStatus)
      assert status.status == "good"
      assert status.serial == cert_serial_hex(leaf)
      assert status.next_update
      assert is_nil(Repo.one!(Portal.RevocationEndpoint).ocsp_error)
    end

    test "caches a revoked answer with its reason", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub(ocsp_response(pki.ca, leaf, status: :revoked, reason: :keyCompromise))

      assert perform(endpoint) == {:ok, :refreshed}

      assert [status] = Repo.all(Portal.OcspStatus)
      assert status.status == "revoked"
      assert status.reason == "keyCompromise"
      assert status.revoked_at
    end

    test "accepts an answer from a responder the CA delegated to", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub(ocsp_response(pki.ca, leaf, status: :good, delegate: true))

      assert perform(endpoint) == {:ok, :refreshed}
      assert [%{status: "good"}] = Repo.all(Portal.OcspStatus)
    end

    test "refuses an answer signed by anyone else", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub(ocsp_response(pki.ca, leaf, status: :good, signer: pki.untrusted_ca))

      assert failure(endpoint) =~ "untrusted_signer"
      assert Repo.all(Portal.OcspStatus) == []
    end

    test "logs an error when the responder does not know the certificate", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub(ocsp_response(pki.ca, leaf, status: :unknown))

      # Our bug, not the responder's, so it is logged loudly, but it is about one
      # certificate and does not condemn the responder or the rest of the run.
      log = capture_log(fn -> assert perform(endpoint) == {:ok, :refreshed} end)
      assert log =~ "does not know a certificate"
      assert Repo.all(Portal.OcspStatus) == []
    end

    test "does not ask again while the cached answer still stands", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub(ocsp_response(pki.ca, leaf, status: :good))
      assert perform(endpoint) == {:ok, :refreshed}

      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert perform(endpoint) == {:ok, :refreshed}
      assert [%{status: "good"}] = Repo.all(Portal.OcspStatus)
    end

    test "asks again once the answer has expired", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub(ocsp_response(pki.ca, leaf, status: :good, next_update: nil))
      assert perform(endpoint) == {:ok, :refreshed}

      stub(ocsp_response(pki.ca, leaf, status: :revoked))
      assert perform(endpoint) == {:ok, :refreshed}
      assert [%{status: "revoked"}] = Repo.all(Portal.OcspStatus)
    end

    test "asks nothing when no device has presented a certificate", %{
      account: account,
      pki: pki
    } do
      endpoint = endpoint_fixture(account, pki.ca_der)
      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert perform(endpoint) == {:ok, :refreshed}
      assert Repo.all(Portal.OcspStatus) == []
    end

    test "cuts the session of a certificate it newly finds revoked", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      Portal.PG.register(device.id)
      stub(ocsp_response(pki.ca, leaf, status: :revoked))

      assert perform(endpoint) == {:ok, :refreshed}

      issuer = X509.subject(pki.ca_der)
      serial = cert_serial_hex(leaf)
      assert_receive {:certificate_revoked, ^issuer, ^serial}
    end

    test "does not cut a session twice for the same revocation", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub(ocsp_response(pki.ca, leaf, status: :revoked, next_update: nil))
      assert perform(endpoint) == {:ok, :refreshed}

      Portal.PG.register(device.id)
      stub(ocsp_response(pki.ca, leaf, status: :revoked, next_update: nil))
      assert perform(endpoint) == {:ok, :refreshed}

      refute_receive {:certificate_revoked, _issuer, _serial}
    end

    test "keeps a revocation when an older answer is replayed", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub(ocsp_response(pki.ca, leaf, status: :revoked, next_update: nil))
      assert perform(endpoint) == {:ok, :refreshed}

      # An answer produced before the one we hold, which a cache in front of the
      # responder can serve, must not roll the status back to good.
      stub(ocsp_response(pki.ca, leaf, status: :good, produced: -3600, next_update: nil))
      assert perform(endpoint) == {:ok, :refreshed}

      assert [%{status: "revoked"}] = Repo.all(Portal.OcspStatus)
    end

    test "refuses an answer from an expired delegated responder", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub(ocsp_response(pki.ca, leaf, status: :good, delegate: true, delegate_validity: {-30, -1}))

      assert failure(endpoint) =~ "untrusted_signer"
      assert Repo.all(Portal.OcspStatus) == []
    end

    test "stops asking once the responder stops answering", %{account: account, pki: pki} do
      for _ <- 1..3 do
        attested_device(account, pki, leaf(pki, :rsa))
      end

      endpoint = endpoint_fixture(account, pki.ca_der)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Sync, fn conn ->
        Agent.update(counter, &(&1 + 1))
        Req.Test.transport_error(conn, :econnrefused)
      end)

      capture_log(fn -> assert perform(endpoint) == {:ok, :failed} end)

      # Each question is retried four times, so walking a whole fleet through a
      # responder that is down would take the job hours.
      assert Agent.get(counter, & &1) <= 4
    end

    test "keeps asking after a certificate the responder does not know", %{
      account: account,
      pki: pki
    } do
      known = leaf(pki, :rsa)
      attested_device(account, pki, known)
      attested_device(account, pki, leaf(pki, :ec))
      endpoint = endpoint_fixture(account, pki.ca_der)

      Req.Test.stub(Sync, fn conn ->
        Plug.Conn.send_resp(conn, 200, ocsp_response(pki.ca, known, status: :unknown))
      end)

      # One certificate the responder cannot place says nothing about the rest.
      log = capture_log(fn -> assert perform(endpoint) == {:ok, :refreshed} end)
      assert log =~ "does not know a certificate"
    end

    test "does nothing when the endpoint is gone", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      Repo.delete_all(Portal.RevocationEndpoint)

      assert perform(endpoint) == {:ok, :deleted}
    end
  end

  defp perform(endpoint) do
    Sync.perform(%Oban.Job{
      args: %{
        "account_id" => endpoint.account_id,
        "issuer" => Base.encode64(endpoint.issuer),
        "distribution_point" => endpoint.distribution_point
      }
    })
  end

  defp failure(endpoint) do
    log = capture_log(fn -> assert perform(endpoint) == {:ok, :failed} end)
    assert Repo.one!(Portal.RevocationEndpoint).ocsp_error
    log
  end

  defp attested_device(account, pki, leaf) do
    Portal.DeviceFixtures.client_fixture(
      account: account,
      last_attested_cert_issuer: X509.subject(pki.ca_der),
      last_attested_cert_serial: cert_serial_hex(leaf)
    )
  end

  defp endpoint_fixture(account, issuer_der) do
    issuer = X509.subject(issuer_der)

    Repo.insert!(%Portal.RevocationEndpoint{
      account_id: account.id,
      issuer: issuer,
      distribution_point: @ocsp_url,
      crl_urls: [],
      ocsp_urls: [@ocsp_url],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp stub(body) do
    Req.Test.stub(Sync, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  defp cert_serial_hex(der) do
    {:Certificate, tbs, _algorithm, _signature} = :public_key.der_decode(:Certificate, der)

    tbs |> elem(2) |> Integer.to_string(16)
  end
end
