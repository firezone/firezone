defmodule Portal.DeviceCATest do
  use Portal.DataCase, async: true
  import Ecto.Query
  import Portal.AccountFixtures

  alias Portal.{DeviceCA, DeviceCertificateAuthority}

  describe "ensure/1" do
    test "creates a self-signed CA for the account" do
      account = account_fixture()

      assert {:ok, %DeviceCertificateAuthority{} = ca} = DeviceCA.ensure(account.id)
      assert ca.key_id == nil
      assert is_binary(ca.private_key)
      assert :public_key.pkix_is_self_signed(ca.certificate)

      certificate = :public_key.pkix_decode_cert(ca.certificate, :otp)
      assert {:ok, {{:ECPoint, <<4, _x::binary-size(32), _y::binary-size(32)>>}, {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}} =
               public_key} = Portal.Crypto.X509.subject_public_key(certificate)

      assert :public_key.pkix_verify(ca.certificate, public_key)

      assert Portal.Crypto.X509.ca_certificate?(certificate)
      assert Portal.Crypto.X509.key_cert_sign_allowed?(certificate)
      assert Portal.Crypto.X509.subject_common_name(certificate) == "Firezone device CA " <> account.id
    end

    test "shows the CA as the account's system trust anchor" do
      account = account_fixture()
      {:ok, ca} = DeviceCA.ensure(account.id)

      trust_anchor = Repo.get_by!(Portal.TrustAnchor, account_id: account.id) |> Repo.preload(:certificates)
      assert trust_anchor.system
      assert trust_anchor.name == "Firezone device CA"
      assert [%{system: true, fingerprint: fingerprint}] = trust_anchor.certificates
      assert fingerprint == Base.encode16(:crypto.hash(:sha256, ca.certificate), case: :lower)
    end

    test "adds the system trust anchor to a CA made before it" do
      account = account_fixture()
      {:ok, ca} = DeviceCA.ensure(account.id)
      Repo.delete_all(from(t in Portal.TrustAnchor, where: t.account_id == ^account.id))

      assert DeviceCA.ensure(account.id) == {:ok, ca}
      assert Repo.get_by!(Portal.TrustAnchor, account_id: account.id, system: true)
    end

    test "keeps the system trust anchor out of the organization's PKI" do
      account = account_fixture()
      {:ok, _ca} = DeviceCA.ensure(account.id)

      assert PortalAPI.Client.DeviceTrust.Database.fetch_anchors(account.id) == []
      refute Portal.Policy.Database.trust_anchors?(account.id)
    end

    test "returns the existing CA" do
      account = account_fixture()

      {:ok, ca} = DeviceCA.ensure(account.id)
      assert DeviceCA.ensure(account.id) == {:ok, ca}
    end

    test "fails for an account that does not exist" do
      assert {:error, %Ecto.Changeset{}} = DeviceCA.ensure(Ecto.UUID.generate())
    end

    test "creates nothing when no key storage is set" do
      Portal.Config.put_env_override(:device_ca_key_storage, nil)
      account = account_fixture()

      assert DeviceCA.ensure(account.id) == {:error, :no_key_storage}
      refute Repo.get_by(DeviceCertificateAuthority, account_id: account.id)
      refute DeviceCA.enabled?()
      assert DeviceCA.delete_key(account.id) == :ok
    end
  end

  describe "issue/2" do
    test "issues a client certificate for the device's key, chained to the account's CA" do
      account = account_fixture()
      {point, private_key} = device_key()

      assert {:ok, %{certificate: certificate, ca_certificate: ca_certificate, key_hash: key_hash}} =
               DeviceCA.issue(account.id, csr(point, private_key))

      {:ok, ca} = DeviceCA.ensure(account.id)
      assert ca_certificate == ca.certificate
      assert {:ok, _result} = :public_key.pkix_path_validation(ca.certificate, [certificate], [])
      assert key_hash == :crypto.hash(:sha256, point)

      otp = :public_key.pkix_decode_cert(certificate, :otp)
      assert {:ok, {{:ECPoint, ^point}, _curve}} = Portal.Crypto.X509.subject_public_key(otp)
      assert Portal.Crypto.X509.subject_common_name(otp) == Base.encode16(key_hash, case: :lower)
      assert Portal.Crypto.X509.client_auth_eku?(otp)
      refute Portal.Crypto.X509.ca_certificate?(otp)

      lifetime = DateTime.diff(Portal.Crypto.X509.not_after(otp), Portal.Crypto.X509.not_before(otp), :day)
      assert lifetime == 90
    end

    test "refuses a CSR whose signature does not match its key" do
      {point, _private_key} = device_key()
      {_other_point, other_key} = device_key()

      assert DeviceCA.issue(account_fixture().id, csr(point, other_key)) ==
               {:error, :invalid_csr}
    end

    test "refuses a key that is not P-256" do
      {:ECPrivateKey, _, _, curve, point, _} = private_key = :public_key.generate_key({:namedCurve, :secp384r1})

      assert DeviceCA.issue(account_fixture().id, csr(point, private_key, curve)) ==
               {:error, :unsupported_key}
    end

    test "refuses bytes that are not a CSR" do
      assert DeviceCA.issue(account_fixture().id, "not a csr") == {:error, :invalid_csr}
    end
  end

  describe "Local" do
    test "signs with the key it created" do
      {:ok, %{public_key: public_key} = key} = DeviceCA.Local.create_key(Ecto.UUID.generate())
      digest = :crypto.hash(:sha256, "message")

      {:ok, signature} = DeviceCA.Local.sign(key, digest)
      assert :public_key.verify({:digest, digest}, :sha256, signature, public_key)
    end

    test "gives each account its own key" do
      {:ok, first} = DeviceCA.Local.create_key(Ecto.UUID.generate())
      {:ok, second} = DeviceCA.Local.create_key(Ecto.UUID.generate())

      assert first.private_key != second.private_key
    end

    test "signs only with a key from the database" do
      assert DeviceCA.Local.sign(%{key_id: "https://vault.example.test/keys/a/1", private_key: nil}, :crypto.hash(:sha256, "")) ==
               {:error, :unknown_key}
    end
  end

  describe "DeviceCertificateAuthority" do
    test "keeps the key in exactly one place" do
      account = account_fixture()
      {:ok, ca} = DeviceCA.ensure(account.id)
      Repo.delete!(ca)

      changeset =
        %DeviceCertificateAuthority{}
        |> Ecto.Changeset.change(account_id: account.id, key_id: "a", private_key: "b", certificate: "c")
        |> DeviceCertificateAuthority.changeset()

      assert {:error, changeset} = Repo.insert(changeset)
      assert "is invalid" in errors_on(changeset).key_id
    end
  end

  defp device_key do
    {:ECPrivateKey, _, _, _, point, _} = private_key = :public_key.generate_key({:namedCurve, :secp256r1})
    {point, private_key}
  end

  defp csr(point, private_key, curve \\ {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}) do
    info =
      {:CertificationRequestInfo, :v1, {:rdnSequence, []},
       {:CertificationRequestInfo_subjectPKInfo,
        {:CertificationRequestInfo_subjectPKInfo_algorithm, {1, 2, 840, 10_045, 2, 1},
         {:asn1_OPENTYPE, :public_key.der_encode(:EcpkParameters, curve)}}, point}, []}

    signature = :public_key.sign(:public_key.der_encode(:CertificationRequestInfo, info), :sha256, private_key)

    :public_key.der_encode(
      :CertificationRequest,
      {:CertificationRequest, info, {:CertificationRequest_signatureAlgorithm, {1, 2, 840, 10_045, 4, 3, 2}, :asn1_NOVALUE},
       signature}
    )
  end
end
