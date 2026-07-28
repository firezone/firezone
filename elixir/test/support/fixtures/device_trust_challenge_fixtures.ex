defmodule Portal.DeviceTrustChallengeFixtures do
  @moduledoc """
  Runtime-generated PKI for the device-trust challenge flow.

  `pki/0` mints a fresh trusted CA (with an intermediate) and an unrelated
  untrusted CA; `leaf/2` and `response_entry/4` mint client-authentication
  leaves under them, including expired, not-yet-valid, and
  key-usage-restricted profiles. Nothing is stored on disk, so no fixture
  can silently expire.
  """

  require Record

  Record.defrecordp(
    :ec_private_key,
    :ECPrivateKey,
    Record.extract(:ECPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :rsa_private_key,
    :RSAPrivateKey,
    Record.extract(:RSAPrivateKey, from_lib: "public_key/include/public_key.hrl")
  )

  @cn_oid {2, 5, 4, 3}
  @ou_oid {2, 5, 4, 11}
  @basic_constraints_oid {2, 5, 29, 19}
  @key_usage_oid {2, 5, 29, 15}
  @extended_key_usage_oid {2, 5, 29, 37}
  @subject_alt_name_oid {2, 5, 29, 17}
  @client_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @server_auth_oid {1, 3, 6, 1, 5, 5, 7, 3, 1}
  @ec_public_key_oid {1, 2, 840, 10_045, 2, 1}
  @p256_oid {1, 2, 840, 10_045, 3, 1, 7}
  @ecdsa_sha256_oid {1, 2, 840, 10_045, 4, 3, 2}
  @rsa_encryption_oid {1, 2, 840, 113_549, 1, 1, 1}

  @leaf_cn "dev.firezone.device-trust"

  @typed_sans [
    {:uniformResourceIdentifier, ~c"firezone://serial/C02XK1ZGJGH5"},
    {:uniformResourceIdentifier, ~c"firezone://udid/7a461ff9-0be2-64a9-a418-539d9a21827b"},
    {:uniformResourceIdentifier, ~c"firezone://intune-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"}
  ]

  @doc """
  Mints a fresh PKI: a trusted CA with an intermediate, plus an unrelated
  untrusted CA. Returns issuer handles alongside their DER certs.
  """
  def pki do
    ca = new_ca("Firezone Device Trust Test CA")
    intermediate = new_intermediate(ca, "Firezone Device Trust Test Intermediate CA")
    untrusted_ca = new_ca("Firezone Untrusted Test CA")

    %{
      ca: ca,
      intermediate: intermediate,
      untrusted_ca: untrusted_ca,
      ca_der: ca.cert_der,
      intermediate_der: intermediate.cert_der,
      untrusted_ca_der: untrusted_ca.cert_der
    }
  end

  @doc """
  Returns `{leaf_der, private_key}` for the named profile, minted under the
  given PKI. `private_key` is decoded and ready for `:public_key.sign/3`.

  Profiles: `:rsa`, `:ec`, `:via_intermediate`, `:no_eku`, `:untrusted`,
  `:no_digital_signature` (keyAgreement-only Key Usage), `:expired`,
  `:not_yet_valid`, and `:no_identifiers` (SAN-less, subject-only). A keyword
  list mints a custom leaf under the trusted CA (`:cn`, `:ous`, `:sans`,
  `:eku`, `:key_usage`, `:validity`, `:key`).
  """
  def leaf(pki, opts) when is_list(opts), do: issue_leaf(pki.ca, opts)

  def leaf(pki, :rsa), do: issue_leaf(pki.ca, key: gen_rsa_key(), sans: @typed_sans)

  def leaf(pki, :ec), do: issue_leaf(pki.ca, sans: @typed_sans)

  def leaf(pki, :via_intermediate) do
    issue_leaf(pki.intermediate,
      sans: [{:uniformResourceIdentifier, ~c"firezone://serial/DMPXK1ZGXYZ9"}]
    )
  end

  def leaf(pki, :no_eku), do: issue_leaf(pki.ca, eku: [@server_auth_oid], sans: @typed_sans)

  def leaf(pki, :untrusted), do: issue_leaf(pki.untrusted_ca, sans: @typed_sans)

  def leaf(pki, :no_digital_signature),
    do: issue_leaf(pki.ca, key_usage: [:keyAgreement], sans: @typed_sans)

  def leaf(pki, :expired), do: issue_leaf(pki.ca, validity: {-730, -1}, sans: @typed_sans)

  def leaf(pki, :not_yet_valid), do: issue_leaf(pki.ca, validity: {1, 730}, sans: @typed_sans)

  def leaf(pki, :no_identifiers), do: issue_leaf(pki.ca, sans: [], ous: ["Engineering"])

  @doc """
  Mints a second intermediate sharing the trusted intermediate's subject DN
  but holding a different key, for chain-building backtracking tests.
  """
  def decoy_intermediate_der(pki) do
    new_intermediate(pki.ca, "Firezone Device Trust Test Intermediate CA").cert_der
  end

  @doc """
  Builds a `device_trust_response` entry (base64 leaf + optional
  intermediates and a base64 signature over `nonce`) for the named profile.
  """
  def response_entry(pki, name, nonce, opts \\ []) do
    {leaf_der, private_key} = leaf(pki, name)
    digest = Keyword.get(opts, :digest, :sha256)
    intermediates = Keyword.get(opts, :intermediates, [])

    signature = :public_key.sign(nonce, digest, private_key)

    %{
      "certs" => Enum.map([leaf_der | intermediates], &Base.encode64/1),
      "signed_challenge" => Base.encode64(signature)
    }
  end

  defp new_ca(common_name) do
    key = gen_ec_key()
    subject = rdn(common_name)
    cert_der = sign_cert(subject, key, subject, spki(key), ca_extensions(), {-1, 3650})
    %{cert_der: cert_der, key: key, subject: subject}
  end

  defp new_intermediate(parent, common_name) do
    key = gen_ec_key()
    subject = rdn(common_name)

    cert_der =
      sign_cert(parent.subject, parent.key, subject, spki(key), ca_extensions(), {-1, 3650})

    %{cert_der: cert_der, key: key, subject: subject}
  end

  defp issue_leaf(issuer, opts) do
    key = Keyword.get(opts, :key) || gen_ec_key()
    validity = Keyword.get(opts, :validity, {-1, 365})
    subject = rdn(Keyword.get(opts, :cn, @leaf_cn), Keyword.get(opts, :ous, []))

    extensions =
      [{:Extension, @extended_key_usage_oid, false, Keyword.get(opts, :eku, [@client_auth_oid])}] ++
        case Keyword.get(opts, :sans, []) do
          [] -> []
          sans -> [{:Extension, @subject_alt_name_oid, false, sans}]
        end ++
        case Keyword.get(opts, :key_usage) do
          nil -> []
          usages -> [{:Extension, @key_usage_oid, true, usages}]
        end

    cert_der = sign_cert(issuer.subject, issuer.key, subject, spki(key), extensions, validity)
    {cert_der, key}
  end

  defp ca_extensions do
    [
      {:Extension, @basic_constraints_oid, true, {:BasicConstraints, true, :asn1_NOVALUE}},
      {:Extension, @key_usage_oid, true, [:keyCertSign, :cRLSign]}
    ]
  end

  defp sign_cert(issuer_rdn, issuer_key, subject_rdn, spki, extensions, {from_days, to_days}) do
    now = DateTime.utc_now()

    tbs =
      {:OTPTBSCertificate, :v3, serial_number(),
       {:SignatureAlgorithm, @ecdsa_sha256_oid, :asn1_NOVALUE}, issuer_rdn,
       {:Validity, utc_time(DateTime.add(now, from_days, :day)),
        utc_time(DateTime.add(now, to_days, :day))}, subject_rdn, spki, :asn1_NOVALUE,
       :asn1_NOVALUE, extensions}

    :public_key.pkix_sign(tbs, issuer_key)
  end

  defp gen_ec_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  defp gen_rsa_key, do: :public_key.generate_key({:rsa, 2048, 65_537})

  defp spki(ec_private_key(publicKey: point)) do
    {:OTPSubjectPublicKeyInfo,
     {:PublicKeyAlgorithm, @ec_public_key_oid, {:namedCurve, @p256_oid}}, {:ECPoint, point}}
  end

  defp spki(rsa_private_key(modulus: modulus, publicExponent: exponent)) do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @rsa_encryption_oid, :NULL},
     {:RSAPublicKey, modulus, exponent}}
  end

  defp rdn(common_name, organizational_units \\ []) do
    ou_rdns =
      Enum.map(organizational_units, &[{:AttributeTypeAndValue, @ou_oid, {:utf8String, &1}}])

    {:rdnSequence, [[{:AttributeTypeAndValue, @cn_oid, {:utf8String, common_name}}] | ou_rdns]}
  end

  defp utc_time(datetime) do
    {:utcTime, datetime |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}
  end

  defp serial_number, do: 8 |> :crypto.strong_rand_bytes() |> :binary.decode_unsigned()
end
