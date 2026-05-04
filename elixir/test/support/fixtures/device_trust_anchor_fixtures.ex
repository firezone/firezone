defmodule Portal.DeviceTrustAnchorFixtures do
  @moduledoc """
  Test helpers for creating device trust anchors.

  The checked-in certificate fixtures under `device_trust_anchors/` are
  synthetic and generated with OpenSSL. Regenerate them with `openssl req -x509`
  for the CA and leaf fixtures, `openssl x509 -outform DER` for the `.der`
  variants, and `openssl genpkey` for the negative private key fixture.

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
  """

  import Portal.AccountFixtures

  @fixtures_dir Path.expand("device_trust_anchors", __DIR__)
  @issuing_cert_der_path Path.join(@fixtures_dir, "issuing_ca.der")
  @issuing_cert_pem_path Path.join(@fixtures_dir, "issuing_ca.pem")
  @additional_ca_der_path Path.join(@fixtures_dir, "additional_ca.der")
  @additional_ca_pem_path Path.join(@fixtures_dir, "additional_ca.pem")
  @leaf_cert_der_path Path.join(@fixtures_dir, "leaf_cert.der")
  @leaf_cert_pem_path Path.join(@fixtures_dir, "leaf_cert.pem")
  @no_key_usage_ca_der_path Path.join(@fixtures_dir, "no_key_usage_ca.der")
  @missing_key_cert_sign_ca_der_path Path.join(@fixtures_dir, "missing_key_cert_sign_ca.der")
  @private_key_pem_path Path.join(@fixtures_dir, "invalid_private_key.pem")

  @doc """
  Returns the sample device trust anchor certificate as base64-encoded DER.
  """
  def sample_cert_base64 do
    sample_cert_der()
    |> Base.encode64()
  end

  @doc """
  Returns the sample device trust anchor certificate as raw DER bytes.
  """
  def sample_cert_der do
    File.read!(@issuing_cert_der_path)
  end

  @doc """
  Returns the sample device trust anchor certificate as PEM text.
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
  Generate valid device trust anchor attributes with sensible defaults.
  """
  def valid_device_trust_anchor_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Device Trust Anchor #{unique_num}",
      certs: [sample_cert_der()]
    })
  end

  @doc """
  Generate a device trust anchor with valid default attributes.
  """
  def device_trust_anchor_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || account_fixture()

    trust_anchor_attrs =
      attrs
      |> Map.delete(:account)
      |> valid_device_trust_anchor_attrs()

    {:ok, trust_anchor} =
      %Portal.DeviceTrustAnchor{}
      |> Ecto.Changeset.cast(trust_anchor_attrs, [:name, :certs])
      |> Ecto.Changeset.put_assoc(:account, account)
      |> Portal.DeviceTrustAnchor.changeset()
      |> Portal.Repo.insert()

    trust_anchor
  end
end
