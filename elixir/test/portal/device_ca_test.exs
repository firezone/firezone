defmodule Portal.DeviceCATest do
  use Portal.DataCase, async: true
  import Portal.AccountFixtures

  alias Portal.{DeviceCA, DeviceCertificateAuthority}

  describe "ensure/1" do
    test "creates a self-signed CA for the account" do
      account = account_fixture()

      assert {:ok, %DeviceCertificateAuthority{} = ca} = DeviceCA.ensure(account.id)
      assert ca.key_id == "local:" <> account.id
      assert :public_key.pkix_is_self_signed(ca.certificate)

      {:ok, public_key} = DeviceCA.Local.create_key(account.id)
      ec_params = {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}
      assert :public_key.pkix_verify(ca.certificate, {{:ECPoint, public_key.public_key}, ec_params})

      certificate = :public_key.pkix_decode_cert(ca.certificate, :otp)
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
    test "derives a different key for each account" do
      {:ok, a} = DeviceCA.Local.create_key(Ecto.UUID.generate())
      {:ok, b} = DeviceCA.Local.create_key(Ecto.UUID.generate())

      assert a.public_key != b.public_key
    end

    test "signs only with its own keys" do
      assert DeviceCA.Local.sign("https://vault.example.test/keys/a/1", :crypto.hash(:sha256, "")) ==
               {:error, :unknown_key}
    end
  end
end
