defmodule PortalAPI.Client.DeviceTrustTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.SubjectFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures
  import Portal.DeviceTrustChallengeFixtures

  alias PortalAPI.Client.DeviceTrust
  alias Portal.Crypto.X509

  describe "fetch_enabled_anchors/1" do
    setup do
      account = account_fixture()
      subject = subject_fixture(account: account)
      %{account: account, subject: subject}
    end

    test "returns no anchors when the feature is disabled", %{account: account, subject: subject} do
      trust_anchor_fixture(account: account, certs: [pki().ca_der])
      assert DeviceTrust.fetch_enabled_anchors(subject) == []
    end

    test "returns no anchors when the account has none uploaded", %{subject: subject} do
      enable_feature(:trust_anchors)
      assert DeviceTrust.fetch_enabled_anchors(subject) == []
    end

    test "returns anchors when the feature is enabled and the account has one", %{
      account: account,
      subject: subject
    } do
      enable_feature(:trust_anchors)
      trust_anchor_fixture(account: account, certs: [pki().ca_der])
      assert [_anchor | _rest] = DeviceTrust.fetch_enabled_anchors(subject)
    end
  end

  describe "verify_response/3" do
    setup do
      account = account_fixture()
      enable_feature(:trust_anchors)
      pki = pki()
      trust_anchor_fixture(account: account, certs: [pki.ca_der])
      subject = subject_fixture(account: account)
      anchors = DeviceTrust.fetch_enabled_anchors(subject)
      %{account: account, pki: pki, nonce: DeviceTrust.nonce(), anchors: anchors}
    end

    test "verifies an RSA leaf and extracts typed identifiers", %{
      pki: pki,
      nonce: nonce,
      anchors: anchors
    } do
      entry = response_entry(pki, :rsa, nonce)

      assert {:ok, verified} = DeviceTrust.verify_response([entry], nonce, anchors)
      assert verified.identifiers.last_attested_device_serial == "C02XK1ZGJGH5"
      assert verified.identifiers.last_attested_device_uuid == "7a461ff9-0be2-64a9-a418-539d9a21827b"
      assert verified.identifiers.last_attested_mdm_device_id == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
      assert is_binary(verified.last_attested_cert_fingerprint)
      assert is_binary(verified.last_attested_cert_serial)
    end

    test "verifies an EC P-256 leaf", %{pki: pki, nonce: nonce, anchors: anchors} do
      entry = response_entry(pki, :ec, nonce)
      assert {:ok, verified} = DeviceTrust.verify_response([entry], nonce, anchors)
      assert verified.identifiers.last_attested_device_serial == "C02XK1ZGJGH5"
    end

    test "accepts an intermediate supplied by the client", %{
      pki: pki,
      nonce: nonce,
      anchors: anchors
    } do
      entry = response_entry(pki, :via_intermediate, nonce, intermediates: [pki.intermediate_der])
      assert {:ok, verified} = DeviceTrust.verify_response([entry], nonce, anchors)
      assert verified.identifiers.last_attested_device_serial == "DMPXK1ZGXYZ9"
    end

    test "rejects a leaf without client-auth EKU", %{pki: pki, nonce: nonce, anchors: anchors} do
      entry = response_entry(pki, :no_eku, nonce)
      assert {:error, :verification_failed} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects a leaf whose key usage omits digitalSignature", %{
      pki: pki,
      nonce: nonce,
      anchors: anchors
    } do
      entry = response_entry(pki, :no_digital_signature, nonce)
      assert {:error, :verification_failed} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects an expired leaf", %{pki: pki, nonce: nonce, anchors: anchors} do
      entry = response_entry(pki, :expired, nonce)
      assert {:error, :verification_failed} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects a not-yet-valid leaf", %{pki: pki, nonce: nonce, anchors: anchors} do
      entry = response_entry(pki, :not_yet_valid, nonce)
      assert {:error, :verification_failed} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects a leaf that does not chain to an anchor", %{
      pki: pki,
      nonce: nonce,
      anchors: anchors
    } do
      entry = response_entry(pki, :untrusted, nonce)
      assert {:error, :verification_failed} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects a signature over the wrong nonce", %{pki: pki, nonce: nonce, anchors: anchors} do
      entry = response_entry(pki, :rsa, :crypto.strong_rand_bytes(32))
      assert {:error, :verification_failed} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects an oversized certificate without decoding it", %{
      nonce: nonce,
      anchors: anchors
    } do
      huge = Base.encode64(:crypto.strong_rand_bytes(64_000))
      entry = %{"certs" => [huge], "signed_challenge" => Base.encode64(<<1>>)}
      assert {:error, :no_usable_cert} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "rejects an oversized signature", %{pki: pki, nonce: nonce, anchors: anchors} do
      entry =
        pki
        |> response_entry(:rsa, nonce)
        |> Map.put("signed_challenge", Base.encode64(:crypto.strong_rand_bytes(8_000)))

      assert {:error, :no_usable_cert} = DeviceTrust.verify_response([entry], nonce, anchors)
    end

    test "returns no_usable_cert for an empty or garbage payload", %{nonce: nonce, anchors: anchors} do
      assert {:error, :no_usable_cert} = DeviceTrust.verify_response([], nonce, anchors)
      assert {:error, :no_usable_cert} = DeviceTrust.verify_response([%{}], nonce, anchors)
    end
  end

  describe "extract_identifiers/1" do
    defp otp(leaf_name) do
      {der, _key} = leaf(pki(), leaf_name)
      {:ok, otp} = X509.decode_der_certificate(der, :otp)
      otp
    end

    test "reads every typed URI SAN into its column" do
      identifiers = DeviceTrust.extract_identifiers(otp(:rsa))
      assert identifiers.last_attested_device_serial == "C02XK1ZGJGH5"
      assert identifiers.last_attested_device_uuid == "7a461ff9-0be2-64a9-a418-539d9a21827b"
      assert identifiers.last_attested_mdm_device_id == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
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

    test "trims and rejects empty values" do
      assert DeviceTrust.normalize_identifier(:last_attested_device_serial, "   ") == nil
    end
  end
end
