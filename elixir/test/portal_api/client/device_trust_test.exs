defmodule PortalAPI.Client.DeviceTrustTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.SubjectFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures
  import Portal.DeviceTrustFixtures

  alias PortalAPI.Client.DeviceTrust
  alias Portal.Crypto.X509

  @attestation_url "https://mtls.firezone.test/"
  @attestation_host "mtls.firezone.test"

  describe "attest/2 when there is nothing to attest" do
    setup do
      account = account_fixture()
      subject = subject_fixture(account: account)
      pki = pki()

      %{account: account, subject: subject, pki: pki}
    end

    test "does not attest when no attestation host is configured", %{
      account: account,
      subject: subject,
      pki: pki
    } do
      enable_feature(:device_trust)
      trust_anchor_fixture(account: account, certs: [pki.ca_der])

      assert DeviceTrust.attest(connect_info(leaf(pki, :rsa)), subject) ==
               {:error, :not_attestation_host}
    end

    test "does not attest when the feature is off", %{
      account: account,
      subject: subject,
      pki: pki
    } do
      configure_attestation_host()
      trust_anchor_fixture(account: account, certs: [pki.ca_der])

      assert DeviceTrust.attest(connect_info(leaf(pki, :rsa)), subject) ==
               {:error, :no_trust_anchors}
    end

    test "reports no anchors when the account has none uploaded", %{
      subject: subject,
      pki: pki
    } do
      configure_attestation_host()
      enable_feature(:device_trust)

      assert DeviceTrust.attest(connect_info(leaf(pki, :rsa)), subject) ==
               {:error, :no_trust_anchors}
    end
  end

  describe "attest/2 when the device_trust feature is off" do
    setup do
      configure_attestation_host()
      start_revocation_endpoint_queue()

      account = account_fixture()
      pki = pki()
      trust_anchor_fixture(account: account, certs: [pki.ca_der])
      subject = subject_fixture(account: account)

      %{account: account, pki: pki, subject: subject}
    end

    test "the certificate is refused rather than trusted unchecked", %{
      pki: pki,
      subject: subject
    } do
      connect_info = connect_info(leaf(pki, :rsa))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :no_trust_anchors}
    end

    test "nothing is recorded about the certificate's CA", %{pki: pki, subject: subject} do
      assert {:error, :no_trust_anchors} =
               DeviceTrust.attest(connect_info(leaf(pki, :with_crl)), subject)

      Portal.Queue.flush(:revocation_endpoint_queue)

      assert Repo.all(Portal.RevocationEndpoint) == []
      assert all_enqueued(worker: Portal.Ocsp.Sync) == []
    end
  end

  describe "attest/2" do
    setup do
      configure_attestation_host()
      start_revocation_endpoint_queue()

      account = account_fixture()
      enable_feature(:device_trust)
      pki = pki()
      trust_anchor_fixture(account: account, certs: [pki.ca_der])
      subject = subject_fixture(account: account)

      %{account: account, pki: pki, subject: subject}
    end

    test "verifies an RSA leaf and extracts typed identifiers", %{pki: pki, subject: subject} do
      assert {:ok, verified} = DeviceTrust.attest(connect_info(leaf(pki, :rsa)), subject)
      assert verified.identifiers.last_attested_device_serial == "C02XK1ZGJGH5"

      assert verified.identifiers.last_attested_device_uuid ==
               "7a461ff9-0be2-64a9-a418-539d9a21827b"

      assert verified.identifiers.last_attested_mdm_device_id ==
               "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"

      assert is_binary(verified.last_attested_cert_fingerprint)
      assert is_binary(verified.last_attested_cert_serial)
    end

    test "verifies an EC P-256 leaf", %{pki: pki, subject: subject} do
      assert {:ok, verified} = DeviceTrust.attest(connect_info(leaf(pki, :ec)), subject)
      assert verified.identifiers.last_attested_device_serial == "C02XK1ZGJGH5"
    end

    test "chains through an uploaded intermediate", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      trust_anchor_fixture(account: account, certs: [pki.intermediate_der])
      connect_info = connect_info(leaf(pki, :via_intermediate))

      assert {:ok, verified} = DeviceTrust.attest(connect_info, subject)
      assert verified.identifiers.last_attested_device_serial == "DMPXK1ZGXYZ9"
    end

    test "rejects a leaf whose intermediate was not uploaded", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :via_intermediate))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :untrusted_chain}
    end

    test "backtracks across intermediates sharing a subject DN", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      trust_anchor_fixture(account: account, certs: [decoy_intermediate_der(pki)])
      trust_anchor_fixture(account: account, certs: [pki.intermediate_der])
      connect_info = connect_info(leaf(pki, :via_intermediate))

      assert {:ok, verified} = DeviceTrust.attest(connect_info, subject)
      assert verified.identifiers.last_attested_device_serial == "DMPXK1ZGXYZ9"
    end

    test "rejects a trusted cert carrying no device identifiers", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :no_identifiers))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :no_device_identifiers}
    end


    test "rejects a cert whose only identifier exceeds the length bound", %{
      pki: pki,
      subject: subject
    } do
      long_serial = String.duplicate("AB", 130)

      connect_info =
        connect_info(
          leaf(pki, sans: [{:uniformResourceIdentifier, ~c"firezone://serial/#{long_serial}"}])
        )

      assert DeviceTrust.attest(connect_info, subject) == {:error, :no_device_identifiers}
    end

    test "rejects a leaf without client-auth EKU", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :no_eku))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :missing_client_auth_eku}
    end

    test "rejects a leaf whose key usage omits digitalSignature", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :no_digital_signature))

      assert DeviceTrust.attest(connect_info, subject) ==
               {:error, :missing_digital_signature_key_usage}
    end

    test "rejects an expired leaf", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :expired))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :outside_validity_window}
    end

    test "rejects a not-yet-valid leaf", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :not_yet_valid))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :outside_validity_window}
    end

    test "rejects a leaf that does not chain to an anchor", %{pki: pki, subject: subject} do
      connect_info = connect_info(leaf(pki, :untrusted))

      assert DeviceTrust.attest(connect_info, subject) == {:error, :untrusted_chain}
    end

    test "accepts a leaf that asserts only a hardware serial", %{pki: pki, subject: subject} do
      connect_info =
        connect_info(
          leaf(pki, sans: [{:uniformResourceIdentifier, ~c"firezone://serial/C02XK1ZGJGH5"}])
        )

      assert {:ok, verified} = DeviceTrust.attest(connect_info, subject)
      assert verified.identifiers == %{last_attested_device_serial: "C02XK1ZGJGH5"}
    end

    test "refuses a leaf whose serial appears on the anchor's cached CRL", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :rsa)
      serial = leaf |> cert_serial_hex()

      Repo.insert!(%Portal.CrlRevocation{
        account_id: account.id,
        issuer: Portal.Crypto.X509.issuer(leaf),
        distribution_point: "http://crl.example.test/ca.crl",
        serial: serial,
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        inserted_at: DateTime.utc_now()
      })

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert DeviceTrust.attest(connect_info(leaf), subject) ==
                        {:error, :certificate_revoked}
             end) =~ "revoked by its CA"
    end

    test "the same serial revoked by a different issuer does not refuse", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :rsa)

      Repo.insert!(%Portal.CrlRevocation{
        account_id: account.id,
        issuer: Portal.Crypto.X509.subject(pki.untrusted_ca_der),
        distribution_point: "http://crl.example.test/ca.crl",
        serial: cert_serial_hex(leaf),
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        inserted_at: DateTime.utc_now()
      })

      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
    end

    test "a leaf's issuer matches the name its CA signs a CRL under", %{pki: pki} do
      leaf = leaf(pki, :rsa)

      # Self-signed root, so its own subject is the name it signs under.
      assert Portal.Crypto.X509.issuer(leaf) == Portal.Crypto.X509.subject(pki.ca_der)
    end

    test "refuses a leaf a responder reports as revoked", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :rsa)
      ocsp_endpoint(account, pki)

      Repo.insert!(%Portal.OcspStatus{
        account_id: account.id,
        issuer: Portal.Crypto.X509.issuer(leaf),
        serial: cert_serial_hex(leaf),
        status: "revoked",
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        next_update: DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now()
      })

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert DeviceTrust.attest(connect_info(leaf), subject) ==
                        {:error, :certificate_revoked}
             end) =~ "revoked by its CA"
    end

    # A responder outage, or a job that has simply not run yet, must not become
    # an outage for the fleet.
    test "allows a leaf with no cached answer", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :rsa)
      ocsp_endpoint(account, pki)

      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
    end

    test "allows a leaf whose cached answer has expired and asks again", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :rsa)
      ocsp_endpoint(account, pki)

      Repo.insert!(%Portal.OcspStatus{
        account_id: account.id,
        issuer: Portal.Crypto.X509.issuer(leaf),
        serial: cert_serial_hex(leaf),
        status: "good",
        next_update: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now()
      })

      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)

      assert [job] = all_enqueued(worker: Portal.Ocsp.Sync)
      assert job.args["serial"] == cert_serial_hex(leaf)
    end

    test "falls through to the responder when the only list is unfetchable", %{
      account: account,
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :rsa)

      Repo.insert!(%Portal.RevocationEndpoint{
        account_id: account.id,
        issuer: Portal.Crypto.X509.issuer(leaf),
        distribution_point: "ldap://dc.corp.test/CN=CA",
        crl_urls: ["ldap://dc.corp.test/CN=CA"],
        ocsp_urls: ["http://ocsp.example.test"],
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      # Treating an ldap:// list as coverage would leave revocation unenforced
      # while the responder sat unused.
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)

      assert [_job] = all_enqueued(worker: Portal.Ocsp.Sync)
    end

    test "the issuer learns its revocation endpoints from the first leaf", %{
      pki: pki,
      subject: subject
    } do
      assert Repo.all(Portal.RevocationEndpoint) == []

      leaf = leaf(pki, :with_crl)
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)

      Portal.Queue.flush(:revocation_endpoint_queue)

      endpoint = Repo.one!(Portal.RevocationEndpoint)
      assert endpoint.issuer == Portal.Crypto.X509.issuer(leaf)
      assert endpoint.crl_urls == ["http://crl.example.test/ca.crl"]
      assert endpoint.ocsp_urls == ["http://ocsp.example.test"]
      assert endpoint.distribution_point == "http://crl.example.test/ca.crl"
    end

    test "a known endpoint is not enqueued again", %{pki: pki, subject: subject} do
      leaf = leaf(pki, :with_crl)

      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)
      assert [endpoint] = Repo.all(Portal.RevocationEndpoint)

      # A later connect has nothing left to learn, so the queue stays empty and
      # the flush has no rows to write.
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Repo.delete!(endpoint)
      Portal.Queue.flush(:revocation_endpoint_queue)

      assert Repo.all(Portal.RevocationEndpoint) == []
    end

    test "a partition the CA adds later is still learned", %{pki: pki, subject: subject} do
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf(pki, :with_crl)), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)

      assert {:ok, _verified} =
               DeviceTrust.attest(connect_info(leaf(pki, :two_partitions)), subject)

      Portal.Queue.flush(:revocation_endpoint_queue)

      points =
        Portal.RevocationEndpoint |> Repo.all() |> Enum.map(& &1.distribution_point) |> Enum.sort()

      assert "http://crl.example.test/a.crl" in points
      assert "http://crl.example.test/b.crl" in points
    end

    test "the endpoint is learned once and not rewritten by later connects", %{
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :with_crl)
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)

      Repo.update_all(Portal.RevocationEndpoint,
        set: [crl_urls: ["http://mirror.example.test/a.crl"]]
      )

      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)

      assert Repo.one!(Portal.RevocationEndpoint).crl_urls == ["http://mirror.example.test/a.crl"]
    end

    test "a connect asks the responder about its own certificate", %{
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :ocsp_only)
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)

      # The endpoint is only learned once the batch lands, so the first connect
      # has nowhere to send the question yet and the second is what asks.
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)

      assert [job] = all_enqueued(worker: Portal.Ocsp.Sync)
      assert job.args["serial"] == cert_serial_hex(leaf)
      assert job.args["issuer"] == Base.encode64(X509.issuer(leaf))
    end

    test "a CA that publishes a list is not asked through its responder", %{
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :with_crl)
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)

      assert all_enqueued(worker: Portal.Ocsp.Sync) == []
    end

    test "a certificate with a current answer is not asked about again", %{
      pki: pki,
      subject: subject
    } do
      leaf = leaf(pki, :ocsp_only)
      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)
      Portal.Queue.flush(:revocation_endpoint_queue)

      Repo.insert!(%Portal.OcspStatus{
        account_id: subject.account.id,
        issuer: X509.issuer(leaf),
        serial: cert_serial_hex(leaf),
        status: "good",
        next_update: DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second),
        updated_at: DateTime.utc_now()
      })

      assert {:ok, _verified} = DeviceTrust.attest(connect_info(leaf), subject)

      assert all_enqueued(worker: Portal.Ocsp.Sync) == []
    end

    test "rejects a leaf whose serial number cannot be recorded", %{pki: pki, subject: subject} do
      serial = String.to_integer(String.duplicate("f", 300), 16)
      sans = [{:uniformResourceIdentifier, ~c"firezone://serial/C02XK1ZGJGH5"}]
      connect_info = connect_info(leaf(pki, serial: serial, sans: sans))

      assert ExUnit.CaptureLog.capture_log(fn ->
               assert DeviceTrust.attest(connect_info, subject) ==
                        {:error, :malformed_cert_serial}
             end) =~ "serial number is not representable"
    end

    test "does not attest on any host other than the attestation host", %{
      pki: pki,
      subject: subject
    } do
      connect_info = connect_info(leaf(pki, :rsa), host: "api.firezone.test")

      assert DeviceTrust.attest(connect_info, subject) == {:error, :not_attestation_host}
    end

    test "does not attest a connect that carries no host", %{pki: pki, subject: subject} do
      connect_info = pki |> leaf(:rsa) |> connect_info() |> Map.delete(:uri)

      assert DeviceTrust.attest(connect_info, subject) == {:error, :not_attestation_host}
    end

    test "rejects a connect without the header", %{subject: subject} do
      assert DeviceTrust.attest(connect_info_with_header(nil), subject) ==
               {:error, :no_certificate_presented}
    end

    test "rejects an empty header", %{subject: subject} do
      assert DeviceTrust.attest(connect_info_with_header(""), subject) ==
               {:error, :no_certificate_presented}
    end

    test "rejects a header that is not a certificate", %{subject: subject} do
      assert DeviceTrust.attest(connect_info_with_header("not base64!"), subject) ==
               {:error, :invalid_certificate}

      encoded = Base.encode64("not a certificate")

      assert DeviceTrust.attest(connect_info_with_header(encoded), subject) ==
               {:error, :invalid_certificate}
    end

    test "rejects an oversized certificate without decoding it", %{subject: subject} do
      encoded = Base.encode64(:crypto.strong_rand_bytes(64_000))

      assert DeviceTrust.attest(connect_info_with_header(encoded), subject) ==
               {:error, :invalid_certificate}
    end
  end

  describe "extract_identifiers/1" do
    test "reads every typed URI SAN into its column" do
      identifiers = DeviceTrust.extract_identifiers(otp(:rsa))
      assert identifiers.last_attested_device_serial == "C02XK1ZGJGH5"
      assert identifiers.last_attested_device_uuid == "7a461ff9-0be2-64a9-a418-539d9a21827b"
      assert identifiers.last_attested_mdm_device_id == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
    end

    test "splits the comma-joined URI SAN Intune emits for multiple rows" do
      identifiers =
        DeviceTrust.extract_identifiers(
          otp(
            sans: [
              {:uniformResourceIdentifier,
               ~c"firezone://serial/MJLFG7WJ39,firezone://intune-id/fd9c47c1-3a0a-4217-be9b-1a74561844e0"}
            ]
          )
        )

      assert identifiers == %{
               last_attested_device_serial: "MJLFG7WJ39",
               last_attested_mdm_device_id: "fd9c47c1-3a0a-4217-be9b-1a74561844e0"
             }
    end

    test "tolerates whitespace after a join separator" do
      identifiers =
        DeviceTrust.extract_identifiers(
          otp(
            sans: [
              {:uniformResourceIdentifier,
               ~c"firezone://serial/MJLFG7WJ39, firezone://udid/7a461ff9-0be2-64a9-a418-539d9a21827b"}
            ]
          )
        )

      assert identifiers == %{
               last_attested_device_serial: "MJLFG7WJ39",
               last_attested_device_uuid: "7a461ff9-0be2-64a9-a418-539d9a21827b"
             }
    end

    test "keeps the comma inside a Microsoft SID URI joined with a device identifier" do
      identifiers =
        DeviceTrust.extract_identifiers(
          otp(
            sans: [
              {:uniformResourceIdentifier,
               ~c"tag:microsoft.com,2022-09-14:sid:S-1-5-21-1234567890-1234567890-1234567890-1234,firezone://intune-id/fd9c47c1-3a0a-4217-be9b-1a74561844e0"}
            ]
          )
        )

      assert identifiers == %{last_attested_mdm_device_id: "fd9c47c1-3a0a-4217-be9b-1a74561844e0"}
    end

    test "splits comma-joined DNS SANs" do
      identifiers =
        DeviceTrust.extract_identifiers(
          otp(sans: [{:dNSName, ~c"UDID=7a461ff9-0be2-64a9-a418-539d9a21827b,SERIAL=C02TEST12345"}])
        )

      assert identifiers == %{
               last_attested_device_uuid: "7a461ff9-0be2-64a9-a418-539d9a21827b",
               last_attested_device_serial: "C02TEST12345"
             }
    end

    test "falls back past garbage typed values to usable SAN identifiers" do
      identifiers =
        DeviceTrust.extract_identifiers(
          otp(
            sans: [
              {:uniformResourceIdentifier, ~c"firezone://smbios-uuid/IDNotPresentButSettable"},
              {:dNSName, ~c"SERIAL=C02TEST12345"}
            ]
          )
        )

      assert identifiers == %{last_attested_device_serial: "C02TEST12345"}
    end

    test "never consults the subject" do
      assert DeviceTrust.extract_identifiers(
               otp(cn: "FVFHF246Q72X", ous: ["Engineering"], sans: [])
             ) == %{}
    end
  end

  describe "normalize_identifier/2" do
    test "uppercases serials and rejects OEM placeholders" do
      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "c02xk1zgjgh5") ==
               "C02XK1ZGJGH5"

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "To be filled by O.E.M.") ==
               nil

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "System Serial Number") ==
               nil

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "0000000000") == nil

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "Not Applicable") ==
               nil

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "FFFFFFFF") == nil

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "ING" <> <<3>>) ==
               nil
    end

    test "lowercases GUID identifiers and rejects UUID sentinels" do
      assert DeviceTrust.normalize_identifier(
               :last_attested_mdm_device_id,
               "5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3"
             ) == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"

      assert DeviceTrust.normalize_identifier(
               :last_attested_device_uuid,
               "00000000-0000-0000-0000-000000000000"
             ) == nil

      assert DeviceTrust.normalize_identifier(
               :last_attested_device_uuid,
               "IDNotPresentButSettable"
             ) == nil
    end

    test "keeps small numeric MDM device ids" do
      assert DeviceTrust.normalize_identifier(:last_attested_mdm_device_id, "1") == "1"
      assert DeviceTrust.normalize_identifier(:last_attested_mdm_device_id, "10") == "10"
      assert DeviceTrust.normalize_identifier(:last_attested_mdm_device_id, "22") == "22"
      assert DeviceTrust.normalize_identifier(:last_attested_mdm_device_id, "0") == nil
    end

    test "trims and rejects empty values" do
      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "   ") == nil
    end

    test "rejects identifiers longer than the 255-char column limit" do
      at_bound = "C" <> String.duplicate("AB", 127)
      over_bound = String.duplicate("AB", 128)

      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, at_bound) == at_bound
      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, over_bound) == nil
      assert DeviceTrust.normalize_identifier(:last_attested_device_uuid, over_bound) == nil
      assert DeviceTrust.normalize_identifier(:last_attested_mdm_device_id, over_bound) == nil
    end
  end

  defp ocsp_endpoint(account, pki) do
    Repo.insert!(%Portal.RevocationEndpoint{
      account_id: account.id,
      issuer: Portal.Crypto.X509.subject(pki.ca_der),
      distribution_point: "http://ocsp.example.test",
      crl_urls: [],
      ocsp_urls: ["http://ocsp.example.test"],
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp configure_attestation_host do
    Portal.Config.put_env_override(:portal, :mtls_external_url, @attestation_url)
  end

  defp connect_info(der, opts \\ []) do
    connect_info_with_header(Base.encode64(der), opts)
  end

  defp connect_info_with_header(value, opts \\ []) do
    host = Keyword.get(opts, :host, @attestation_host)
    headers = if is_nil(value), do: [], else: [{"x-client-cert", value}]

    %{uri: %URI{scheme: "https", host: host, port: 443, path: "/"}, x_headers: headers}
  end

  defp otp(profile) do
    {:ok, otp} = pki() |> leaf(profile) |> X509.decode_der_certificate(:otp)
    otp
  end

  defp cert_serial_hex(der) do
    {:ok, leaf} = Portal.Crypto.X509.decode_der_certificate(der, :otp)
    leaf |> Portal.Crypto.X509.serial_number() |> Integer.to_string(16)
  end
  defp start_revocation_endpoint_queue do
    start_supervised!(
      {Portal.Queue,
       Keyword.merge(DeviceTrust.revocation_endpoint_queue_opts(),
         callers: [self()],
         flush_on_terminate: false
       )}
    )
  end
end
