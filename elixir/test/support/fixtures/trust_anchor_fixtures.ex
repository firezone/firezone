defmodule Portal.TrustAnchorFixtures do
  @moduledoc """
  Test helpers for creating trust anchors.

  The checked-in certificate fixtures under `trust_anchors/` are synthetic and
  generated with OpenSSL. Regenerate them with `openssl req -x509` for the CA
  and leaf fixtures, `openssl x509 -outform DER` for the `.der` variants, and
  `openssl genpkey` for the negative private key fixture.

  The main `issuing_ca.pem` / `issuing_ca.der` fixture was generated to
  represent a realistic enterprise issuing CA shape we want to allow in this
  field:

  - subject `CN=Company Issuing CA`
  - issuer `CN=Company Root CA`
  - RSA 4096-bit key
  - `sha512WithRSAEncryption`
  - `basicConstraints = critical, CA:true, pathlen:0`
  - `keyUsage = critical, digitalSignature, keyCertSign, cRLSign`
  - `extendedKeyUsage = clientAuth`
  - SKI / AKI plus AIA / CRL extension presence

  The actual serial number, validity timestamps, keys, and URLs are synthetic.

  `ec_ca.pem` / `ec_ca.der` and `ed25519_ca.pem` / `ed25519_ca.der` exercise
  non-RSA key algorithms end to end (X509 field extraction, in particular).
  Regenerated with:

      openssl ecparam -name prime256v1 -genkey -noout -out key.pem
      openssl req -x509 -new -key key.pem -days 3650 -out ec_ca.pem \\
        -subj "/CN=EC Trust Anchor CA" \\
        -addext "basicConstraints=critical,CA:true,pathlen:1" \\
        -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign" \\
        -addext "extendedKeyUsage=clientAuth,serverAuth" \\
        -addext "subjectKeyIdentifier=hash" \\
        -addext "authorityKeyIdentifier=keyid:always" \\
        -addext "subjectAltName=DNS:ca.test.invalid,IP:10.0.0.1" \\
        -addext "crlDistributionPoints=URI:http://crl.test.invalid/ec-ca.crl" \\
        -addext "authorityInfoAccess=OCSP;URI:http://ocsp.test.invalid,caIssuers;URI:http://ca.test.invalid/root.cer"

      openssl genpkey -algorithm ed25519 -out key.pem
      openssl req -x509 -new -key key.pem -days 3650 -out ed25519_ca.pem \\
        -subj "/CN=Ed25519 Trust Anchor CA" \\
        -addext "basicConstraints=critical,CA:true" \\
        -addext "keyUsage=critical,keyCertSign"

  `p384_leaf.pem` / `p384_leaf.der` exercises leaf field extraction (URI and
  DNS SANs, client-auth EKU, subject OUs, P-384 key). Regenerated with:

      openssl ecparam -name secp384r1 -genkey -noout -out key.pem
      openssl req -x509 -new -key key.pem -days 3650 -out p384_leaf.pem \\
        -subj "/CN=dev.firezone.device-trust/OU=Engineering/OU=Device Trust" \\
        -addext "basicConstraints=critical,CA:FALSE" \\
        -addext "keyUsage=critical,digitalSignature" \\
        -addext "extendedKeyUsage=clientAuth" \\
        -addext "subjectAltName=URI:firezone://serial/C02XK1ZGJGH5,URI:firezone://udid/7a461ff9-0be2-64a9-a418-539d9a21827b,DNS:UDID=7A461FF9,DNS:host.test.invalid"
  """

  import Portal.AccountFixtures

  @fixtures_dir Path.expand("trust_anchors", __DIR__)
  @issuing_cert_der_path Path.join(@fixtures_dir, "issuing_ca.der")
  @issuing_cert_pem_path Path.join(@fixtures_dir, "issuing_ca.pem")
  @additional_ca_der_path Path.join(@fixtures_dir, "additional_ca.der")
  @additional_ca_pem_path Path.join(@fixtures_dir, "additional_ca.pem")
  @leaf_cert_der_path Path.join(@fixtures_dir, "leaf_cert.der")
  @leaf_cert_pem_path Path.join(@fixtures_dir, "leaf_cert.pem")
  @no_key_usage_ca_der_path Path.join(@fixtures_dir, "no_key_usage_ca.der")
  @missing_key_cert_sign_ca_der_path Path.join(@fixtures_dir, "missing_key_cert_sign_ca.der")
  @private_key_pem_path Path.join(@fixtures_dir, "invalid_private_key.pem")
  @ec_ca_der_path Path.join(@fixtures_dir, "ec_ca.der")
  @ec_ca_pem_path Path.join(@fixtures_dir, "ec_ca.pem")
  @ed25519_ca_der_path Path.join(@fixtures_dir, "ed25519_ca.der")
  @ed25519_ca_pem_path Path.join(@fixtures_dir, "ed25519_ca.pem")
  @p384_leaf_der_path Path.join(@fixtures_dir, "p384_leaf.der")

  @doc """
  Returns the sample trust anchor certificate as base64-encoded DER.
  """
  def sample_cert_base64 do
    sample_cert_der()
    |> Base.encode64()
  end

  @doc """
  Returns the sample trust anchor certificate as raw DER bytes.
  """
  def sample_cert_der do
    File.read!(@issuing_cert_der_path)
  end

  @doc """
  Returns the sample trust anchor certificate as PEM text.
  """
  def sample_cert_pem do
    File.read!(@issuing_cert_pem_path)
  end

  @doc """
  Returns a PEM-encoded private key for negative validation tests.
  """
  def sample_private_key_pem do
    File.read!(@private_key_pem_path)
  end

  @doc """
  Returns a synthetic non-CA leaf certificate for negative validation tests.
  """
  def sample_leaf_cert_der do
    File.read!(@leaf_cert_der_path)
  end

  @doc """
  Returns the synthetic non-CA leaf certificate as PEM text.
  """
  def sample_leaf_cert_pem do
    File.read!(@leaf_cert_pem_path)
  end

  @doc """
  Returns a CA certificate that omits the Key Usage extension entirely.
  """
  def sample_no_key_usage_ca_der do
    File.read!(@no_key_usage_ca_der_path)
  end

  @doc """
  Returns a CA certificate whose Key Usage omits keyCertSign.
  """
  def sample_missing_key_cert_sign_ca_der do
    File.read!(@missing_key_cert_sign_ca_der_path)
  end

  @doc """
  Returns an additional synthetic CA certificate for bundle parsing tests.
  """
  def sample_additional_ca_der do
    File.read!(@additional_ca_der_path)
  end

  @doc """
  Returns the additional synthetic CA certificate as PEM text.
  """
  def sample_additional_ca_pem do
    File.read!(@additional_ca_pem_path)
  end

  @doc """
  Returns a synthetic ECDSA P-256 CA certificate as raw DER bytes, covering
  Subject Alternative Names, Extended Key Usage, CRL, and Authority
  Information Access extensions.
  """
  def sample_ec_ca_der do
    File.read!(@ec_ca_der_path)
  end

  @doc """
  Returns the synthetic ECDSA P-256 CA certificate as PEM text.
  """
  def sample_ec_ca_pem do
    File.read!(@ec_ca_pem_path)
  end

  @doc """
  Returns a synthetic Ed25519 CA certificate as raw DER bytes.
  """
  def sample_ed25519_ca_der do
    File.read!(@ed25519_ca_der_path)
  end

  @doc """
  Returns a synthetic P-384 leaf certificate as raw DER bytes, covering URI
  and DNS Subject Alternative Names, client-auth EKU, and subject OUs.
  """
  def sample_p384_leaf_der do
    File.read!(@p384_leaf_der_path)
  end

  @doc """
  Returns the synthetic Ed25519 CA certificate as PEM text.
  """
  def sample_ed25519_ca_pem do
    File.read!(@ed25519_ca_pem_path)
  end

  @doc """
  Generate valid trust anchor attributes with sensible defaults.
  """
  def valid_trust_anchor_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Trust Anchor #{unique_num}",
      certs: [sample_cert_der()]
    })
  end

  @doc """
  Generate a trust anchor with valid default attributes.
  """
  def trust_anchor_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || account_fixture()

    trust_anchor_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_trust_anchor_attrs()

    {:ok, trust_anchor} =
      %Portal.TrustAnchor{}
      |> Ecto.Changeset.cast(trust_anchor_attrs, [:name, :certs])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Portal.TrustAnchor.changeset()
      |> Portal.Repo.insert()

    trust_anchor
  end
end
