defmodule Portal.Crypto.X509Test do
  use ExUnit.Case, async: true

  import Portal.TrustAnchorFixtures

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

  describe "pem_encode/1" do
    test "round-trips DER through PEM" do
      pem = X509.pem_encode(sample_cert_der())

      assert X509.pem_encoded?(pem)
      assert {:ok, [{:Certificate, der, :not_encrypted}]} = X509.pem_decode(pem)
      assert der == sample_cert_der()
    end
  end

  describe "field extraction" do
    test "reads subject and issuer common names" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.subject_common_name(cert) == "Company Issuing CA"
      assert X509.issuer_common_name(cert) == "Company Root CA"
    end

    test "reads validity timestamps" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.not_before(cert) == ~U[2026-04-20 16:24:46Z]
      assert X509.not_after(cert) == ~U[2028-04-19 16:24:46Z]
    end

    test "reads the serial number" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.serial_number(cert) == 42_095_695_342_393_971_666_742_022_583_967_287_377_743_815_197
    end

    test "reads the X.509 version" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.version(cert) == :v3
    end

    test "reads full subject and issuer distinguished names" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.subject_name(cert) == "CN=Company Issuing CA"
      assert X509.issuer_name(cert) == "CN=Company Root CA"
    end

    test "reads the signature algorithm" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.signature_algorithm(cert) == "sha512WithRSAEncryption"
    end

    test "reads RSA public key algorithm and size" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.public_key_info(cert) == %{algorithm: "RSA", key_size: 4096}
    end

    test "reads Basic Constraints with an explicit path length" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.basic_constraints(cert) == %{ca: true, path_length: 0}
    end

    test "reads Key Usage flags" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.key_usages(cert) == [:digitalSignature, :keyCertSign, :cRLSign]
    end

    test "reads Extended Key Usage purposes" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())
      assert X509.extended_key_usages(cert) == ["TLS Client Authentication"]
    end

    test "reads Subject and Authority Key Identifiers" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())

      assert X509.subject_key_identifier(cert) ==
               "0b:f6:da:82:21:43:2b:92:c2:dd:78:8b:08:ef:9a:7a:62:fe:7a:87"

      assert X509.authority_key_identifier(cert) ==
               "a6:75:24:dc:85:c2:66:f5:1d:02:49:78:cf:4f:f9:ea:e1:14:81:01"
    end

    test "reads CRL Distribution Points" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())

      assert X509.crl_distribution_points(cert) == [
               "http://primary-cdn.test.invalid/device-trust-anchor/current.crl",
               "http://secondary.test.invalid/device-trust-anchor/current.crl"
             ]
    end

    test "reads Authority Information Access URLs" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_cert_der())

      assert X509.authority_info_access(cert) == %{
               ocsp: [],
               ca_issuers: [
                 "http://primary-cdn.test.invalid/device-trust-anchor/root.cer",
                 "http://secondary.test.invalid/device-trust-anchor/root.cer"
               ]
             }
    end

    test "returns empty defaults when extensions are absent" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ed25519_ca_der())

      assert X509.basic_constraints(cert) == %{ca: true, path_length: nil}
      assert X509.extended_key_usages(cert) == []
      assert X509.subject_alt_names(cert) == []
      assert X509.crl_distribution_points(cert) == []
      assert X509.authority_info_access(cert) == %{ocsp: [], ca_issuers: []}
    end

    test "reads EC public key algorithm, curve, and size" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ec_ca_der())
      assert X509.public_key_info(cert) == %{algorithm: "ECDSA P-256", key_size: 256}
      assert X509.signature_algorithm(cert) == "ecdsa-with-SHA256"
    end

    test "reads Basic Constraints with no path length constraint" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ec_ca_der())
      assert X509.basic_constraints(cert) == %{ca: true, path_length: 1}
    end

    test "reads DNS and IP Subject Alternative Names" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ec_ca_der())
      assert X509.subject_alt_names(cert) == ["DNS:ca.test.invalid", "IP:10.0.0.1"]
    end

    test "reads Extended Key Usage with multiple purposes" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ec_ca_der())

      assert X509.extended_key_usages(cert) == [
               "TLS Client Authentication",
               "TLS Server Authentication"
             ]
    end

    test "reads CRL Distribution Points and Authority Information Access together" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ec_ca_der())
      assert X509.crl_distribution_points(cert) == ["http://crl.test.invalid/ec-ca.crl"]

      assert X509.authority_info_access(cert) == %{
               ocsp: ["http://ocsp.test.invalid"],
               ca_issuers: ["http://ca.test.invalid/root.cer"]
             }
    end

    test "reads Ed25519 public key algorithm and fixed key size" do
      assert {:ok, cert} = X509.decode_der_certificate(sample_ed25519_ca_der())
      assert X509.public_key_info(cert) == %{algorithm: "Ed25519", key_size: 256}
      assert X509.signature_algorithm(cert) == "Ed25519"
    end
  end
end
