defmodule Portal.Crl.SyncTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures
  import Portal.DeviceTrustFixtures
  import ExUnit.CaptureLog

  alias Portal.Crl.Sync
  alias Portal.Crypto.X509

  @crl_url "http://crl.example.test/ca.crl"

  setup do
    account = account_fixture()
    enable_feature(:trust_anchors)
    pki = pki()
    trust_anchor_fixture(account: account, certs: [pki.ca_der])

    %{account: account, pki: pki}
  end

  describe "perform/1" do
    test "caches every serial the CRL revokes", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf], number: 9))

      assert perform(endpoint) == {:ok, :refreshed}

      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.issuer == X509.issuer(leaf)
      assert revocation.serial == cert_serial_hex(leaf)

      assert Repo.one!(Portal.RevocationEndpoint).crl_number == 9
      assert is_nil(Repo.one!(Portal.RevocationEndpoint).crl_error)
    end

    test "replaces the previous set rather than merging into it", %{account: account, pki: pki} do
      first = leaf(pki, :rsa)
      second = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [first]))
      assert perform(endpoint) == {:ok, :refreshed}

      stub_crl(crl(pki.ca, revoked: [second], number: 2))
      assert perform(endpoint) == {:ok, :refreshed}

      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.serial == cert_serial_hex(second)
    end

    test "verifies against the anchor bearing the issuer's name", %{account: account, pki: pki} do
      # Both the root and its intermediate are uploaded, so a leaf validates
      # against either. Only the intermediate signs the list covering it.
      trust_anchor_fixture(account: account, certs: [pki.intermediate_der])
      leaf = leaf(pki, :via_intermediate)
      endpoint = endpoint_fixture(account, pki.intermediate_der)
      stub_crl(crl(pki.intermediate, revoked: [leaf]))

      assert perform(endpoint) == {:ok, :refreshed}
      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.issuer == X509.issuer(leaf)
    end

    test "refuses a CRL signed by anyone else", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.untrusted_ca, revoked: [leaf(pki, :untrusted)]))

      assert failure(endpoint) =~ "crl_issuer_mismatch"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "refuses a CRL published by a different CA at the same address", %{
      account: account,
      pki: pki
    } do
      # The address came from a certificate, so whatever answers it has to be
      # that certificate issuer's list and not another CA's.
      trust_anchor_fixture(account: account, certs: [pki.intermediate_der])
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.intermediate, revoked: [leaf(pki, :via_intermediate)]))

      assert failure(endpoint) =~ "crl_issuer_mismatch"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "refuses a CRL covering only part of its issuer", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)], partial: true))

      assert failure(endpoint) =~ "crl_not_complete"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "refuses a delta CRL", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)], delta: true))

      assert failure(endpoint) =~ "crl_not_complete"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "names an address it cannot speak instead of reporting a fetch failure", %{
      account: account,
      pki: pki
    } do
      endpoint = endpoint_fixture(account, pki.ca_der, crl_url: "ldap://dc.corp.test/CN=CA")

      assert failure(endpoint) =~ "unsupported_url_scheme"
    end

    test "keeps the cached list when the CA is unreachable", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [leaf]))
      assert perform(endpoint) == {:ok, :refreshed}

      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert failure(endpoint) =~ "connection refused"

      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.serial == cert_serial_hex(leaf)
    end

    test "refuses a body that is not a CRL at all", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl("not a crl")

      assert failure(endpoint) =~ "crl_issuer_mismatch"
    end

    test "notifies the session of a certificate that has just been revoked", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      issuer = X509.subject(pki.ca_der)
      serial = cert_serial_hex(leaf)

      Portal.PG.register(device.client_token_id)
      stub_crl(crl(pki.ca, revoked: [leaf]))

      assert perform(endpoint) == {:ok, :refreshed}

      # Named rather than acted on: the device columns record the last
      # certificate a device ever presented, so only the session knows whether
      # this revocation is about the certificate it is actually using.
      assert_receive {:certificate_revoked, ^issuer, ^serial}
    end

    test "leaves a device holding the same serial from another CA alone", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf, issuer_der: pki.untrusted_ca_der)
      endpoint = endpoint_fixture(account, pki.ca_der)

      Portal.PG.register(device.client_token_id)
      stub_crl(crl(pki.ca, revoked: [leaf]))

      assert perform(endpoint) == {:ok, :refreshed}
      refute_receive {:certificate_revoked, _issuer, _serial}
    end

    test "does not notify again for a serial already cached", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [leaf]))
      assert perform(endpoint) == {:ok, :refreshed}

      Portal.PG.register(device.client_token_id)
      stub_crl(crl(pki.ca, revoked: [leaf], number: 2))

      assert perform(endpoint) == {:ok, :refreshed}
      refute_receive {:certificate_revoked, _issuer, _serial}
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
        "issuer" => Base.encode64(endpoint.issuer)
      }
    })
  end

  defp failure(endpoint) do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert perform(endpoint) == {:ok, :failed}
      end)

    assert Repo.one!(Portal.RevocationEndpoint).crl_error
    log
  end

  defp attested_device(account, pki, leaf, attrs \\ []) do
    issuer_der = Keyword.get(attrs, :issuer_der, pki.ca_der)
    token = Portal.TokenFixtures.client_token_fixture(account: account)

    Portal.DeviceFixtures.client_fixture(
      account: account,
      last_attested_cert_issuer: X509.subject(issuer_der),
      last_attested_cert_serial: cert_serial_hex(leaf)
    )
    |> Ecto.Changeset.change(client_token_id: token.id)
    |> Repo.update!()
  end

  defp endpoint_fixture(account, issuer_der, attrs \\ []) do
    issuer = X509.subject(issuer_der)

    Repo.insert!(%Portal.RevocationEndpoint{
      account_id: account.id,
      issuer: issuer,
      issuer_dn: X509.describe_name(issuer),
      crl_url: Keyword.get(attrs, :crl_url, @crl_url),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp stub_crl(body) do
    Req.Test.stub(Sync, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  defp cert_serial_hex(der) do
    {:Certificate, tbs, _algorithm, _signature} = :public_key.der_decode(:Certificate, der)

    tbs |> elem(2) |> Integer.to_string(16)
  end
end
