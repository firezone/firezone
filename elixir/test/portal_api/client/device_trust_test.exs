defmodule PortalAPI.Client.DeviceTrustTest do
  use Portal.DataCase, async: true

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
      enable_feature(:trust_anchors)
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
      enable_feature(:trust_anchors)

      assert DeviceTrust.attest(connect_info(leaf(pki, :rsa)), subject) ==
               {:error, :no_trust_anchors}
    end
  end

  describe "attest/2" do
    setup do
      configure_attestation_host()

      account = account_fixture()
      enable_feature(:trust_anchors)
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

    test "rejects a leaf that asserts no MDM device id", %{pki: pki, subject: subject} do
      connect_info =
        connect_info(
          leaf(pki, sans: [{:uniformResourceIdentifier, ~c"firezone://serial/C02XK1ZGJGH5"}])
        )

      assert DeviceTrust.attest(connect_info, subject) == {:error, :no_mdm_device_id}
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
end
