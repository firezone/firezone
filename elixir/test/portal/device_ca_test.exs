defmodule Portal.DeviceCATest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures

  alias Portal.{DeviceCA, DeviceCertificateAuthority}

  describe "ensure/1" do
    test "creates a self-signed CA for the account" do
      account = account_fixture()

      assert {:ok, %DeviceCertificateAuthority{} = ca} = DeviceCA.ensure(account.id)
      assert "local:" <> _encrypted = ca.key_id
      assert :public_key.pkix_is_self_signed(ca.certificate)

      certificate = :public_key.pkix_decode_cert(ca.certificate, :otp)
      {:ok, {:RSAPublicKey, modulus, _exponent} = public_key} = Portal.Crypto.X509.subject_public_key(certificate)
      assert byte_size(:binary.encode_unsigned(modulus)) == 256
      assert :public_key.pkix_verify(ca.certificate, public_key)

      assert Portal.Crypto.X509.ca_certificate?(certificate)
      assert Portal.Crypto.X509.key_cert_sign_allowed?(certificate)
      assert Portal.Crypto.X509.subject_common_name(certificate) == "Firezone device CA " <> account.id
    end

    test "returns the existing CA" do
      account = account_fixture()

      {:ok, ca} = DeviceCA.ensure(account.id)
      assert DeviceCA.ensure(account.id) == {:ok, ca}
    end

    test "fails for an account that does not exist" do
      assert {:error, %Ecto.Changeset{}} = DeviceCA.ensure(Ecto.UUID.generate())
    end
  end

  describe "Local" do
    test "signs with the key it created" do
      {:ok, %{key_id: key_id, public_key: public_key}} = DeviceCA.Local.create_key(Ecto.UUID.generate())
      digest = :crypto.hash(:sha256, "message")

      {:ok, signature} = DeviceCA.Local.sign(key_id, digest)
      assert :public_key.verify({:digest, digest}, :sha256, signature, public_key)
    end

    test "refuses a key id that was not encrypted with this key base" do
      assert DeviceCA.Local.sign("local:tampered", :crypto.hash(:sha256, "")) == {:error, :unknown_key}
    end

    test "signs only with its own keys" do
      assert DeviceCA.Local.sign("https://vault.example.test/keys/a/1", :crypto.hash(:sha256, "")) ==
               {:error, :unknown_key}
    end
  end
end
