defmodule Portal.Crypto.X509Test do
  use ExUnit.Case, async: true

  import Portal.DeviceTrustAnchorFixtures

  alias Portal.Crypto.X509

  describe "pem_encoded?/1" do
    test "returns true for PEM text" do
      assert X509.pem_encoded?(sample_cert_pem())
    end

    test "returns false for DER bytes" do
      refute X509.pem_encoded?(sample_cert_der())
    end
  end

  describe "pem_decode/1" do
    test "decodes certificate PEM" do
      assert {:ok, [entry]} = X509.pem_decode(sample_cert_pem())
      assert X509.certificate_entry?(entry)
      refute X509.private_key_entry?(entry)
    end

    test "decodes private key PEM" do
      assert {:ok, [entry]} = X509.pem_decode(sample_private_key_pem())
      refute X509.certificate_entry?(entry)
      assert X509.private_key_entry?(entry)
    end

    test "returns invalid for malformed PEM" do
      assert {:error, :invalid} = X509.pem_decode("-----BEGIN CERTIFICATE-----")
    end

    test "returns an empty entry list for unknown PEM labels" do
      assert {:ok, []} =
               X509.pem_decode("-----BEGIN GARBAGE-----\nZm9v\n-----END GARBAGE-----\n")
    end
  end

  describe "decode_der_certificate/2" do
    test "decodes DER certificates to :otp" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert is_tuple(cert)
      assert elem(cert, 0) == :OTPCertificate
    end

    test "decodes DER certificates to :plain" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der(), :plain)
      assert is_tuple(cert)
      assert elem(cert, 0) == :Certificate
    end

    test "returns invalid for malformed DER" do
      assert {:error, :invalid} = X509.decode_der_certificate(String.duplicate(<<0>>, 128))
    end
  end

  describe "plain_certificates/1" do
    test "decodes a DER list into :plain certificates" do
      assert [ca_cert, leaf_cert] =
               X509.plain_certificates([sample_cert_der(), sample_leaf_cert_der()])

      assert is_tuple(ca_cert)
      assert elem(ca_cert, 0) == :Certificate
      assert is_tuple(leaf_cert)
      assert elem(leaf_cert, 0) == :Certificate
    end
  end

  describe "certificate inspection" do
    test "identifies CA certificates" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.ca_certificate?(cert)
      assert X509.key_cert_sign_allowed?(cert)
    end

    test "rejects non-CA certificates as trust anchors" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_leaf_cert_der())
      refute X509.ca_certificate?(cert)
    end

    test "allows CA certificates with no key usage extension" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_no_key_usage_ca_der())
      assert X509.ca_certificate?(cert)
      assert X509.key_cert_sign_allowed?(cert)
    end

    test "detects CA certificates missing keyCertSign" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_missing_key_cert_sign_ca_der())
      assert X509.ca_certificate?(cert)
      refute X509.key_cert_sign_allowed?(cert)
    end
  end
end
