defmodule Portal.Crypto.X509 do
  @moduledoc """
  Low-level X.509 certificate helpers built on Erlang/OTP's `:public_key`.

  This module is intentionally limited to certificate parsing, PEM entry
  inspection, and X.509 extension checks. Application-specific policy, such as
  whether a certificate should be accepted as a stored trust anchor, belongs in
  the caller.
  """

  # Basic Constraints marks whether a certificate is a CA.
  @basic_constraints_oid {2, 5, 29, 19}

  # Key Usage constrains what the certificate's key may be used for.
  @key_usage_oid {2, 5, 29, 15}

  # Common Name, used to read a human-readable subject/issuer off a name.
  @common_name_oid {2, 5, 4, 3}

  # Other extensions surfaced for certificate debugging.
  @extended_key_usage_oid {2, 5, 29, 37}
  @subject_key_identifier_oid {2, 5, 29, 14}
  @authority_key_identifier_oid {2, 5, 29, 35}
  @subject_alt_name_oid {2, 5, 29, 17}
  @crl_distribution_points_oid {2, 5, 29, 31}
  @authority_info_access_oid {1, 3, 6, 1, 5, 5, 7, 1, 1}
  @ocsp_access_method_oid {1, 3, 6, 1, 5, 5, 7, 48, 1}
  @ca_issuers_access_method_oid {1, 3, 6, 1, 5, 5, 7, 48, 2}
  @organizational_unit_oid {2, 5, 4, 11}
  @client_auth_eku_oid {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @ec_public_key_oid {1, 2, 840, 10_045, 2, 1}
  @p384_curve_oid {1, 3, 132, 0, 34}

  # Distinguished Name attribute types, ordered as commonly displayed.
  @dn_attribute_oids %{
    {2, 5, 4, 3} => "CN",
    {2, 5, 4, 10} => "O",
    {2, 5, 4, 11} => "OU",
    {2, 5, 4, 7} => "L",
    {2, 5, 4, 8} => "ST",
    {2, 5, 4, 6} => "C",
    {1, 2, 840, 113_549, 1, 9, 1} => "emailAddress"
  }

  @signature_algorithm_oids %{
    {1, 2, 840, 113_549, 1, 1, 4} => "md5WithRSAEncryption",
    {1, 2, 840, 113_549, 1, 1, 5} => "sha1WithRSAEncryption",
    {1, 2, 840, 113_549, 1, 1, 11} => "sha256WithRSAEncryption",
    {1, 2, 840, 113_549, 1, 1, 12} => "sha384WithRSAEncryption",
    {1, 2, 840, 113_549, 1, 1, 13} => "sha512WithRSAEncryption",
    {1, 2, 840, 10_045, 4, 1} => "ecdsa-with-SHA1",
    {1, 2, 840, 10_045, 4, 3, 1} => "ecdsa-with-SHA224",
    {1, 2, 840, 10_045, 4, 3, 2} => "ecdsa-with-SHA256",
    {1, 2, 840, 10_045, 4, 3, 3} => "ecdsa-with-SHA384",
    {1, 2, 840, 10_045, 4, 3, 4} => "ecdsa-with-SHA512",
    {1, 3, 101, 112} => "Ed25519",
    {1, 3, 101, 113} => "Ed448"
  }

  # Named curves, mapped to their conventional display name and key size.
  @ec_curve_oids %{
    {1, 2, 840, 10_045, 3, 1, 7} => {"ECDSA P-256", 256},
    {1, 3, 132, 0, 34} => {"ECDSA P-384", 384},
    {1, 3, 132, 0, 35} => {"ECDSA P-521", 521},
    {1, 3, 132, 0, 10} => {"ECDSA secp256k1", 256}
  }

  @extended_key_usage_oids %{
    {1, 3, 6, 1, 5, 5, 7, 3, 1} => "TLS Server Authentication",
    {1, 3, 6, 1, 5, 5, 7, 3, 2} => "TLS Client Authentication",
    {1, 3, 6, 1, 5, 5, 7, 3, 3} => "Code Signing",
    {1, 3, 6, 1, 5, 5, 7, 3, 4} => "Email Protection",
    {1, 3, 6, 1, 5, 5, 7, 3, 8} => "Time Stamping",
    {1, 3, 6, 1, 5, 5, 7, 3, 9} => "OCSP Signing"
  }

  @type certificate_format :: :otp | :plain
  @type pem_entry :: {atom(), binary(), term()}

  @doc """
  Returns true when the input appears to be PEM text.
  """
  @spec pem_encoded?(binary()) :: boolean()
  def pem_encoded?(value) when is_binary(value) do
    String.valid?(value) and String.contains?(value, "-----BEGIN")
  end

  @doc """
  Decodes PEM text into Erlang/OTP PEM entries.

  Returns `{:error, :invalid}` when OTP rejects the PEM payload.
  """
  @spec pem_decode(binary()) :: {:ok, [pem_entry()]} | {:error, :invalid}
  def pem_decode(pem) when is_binary(pem) do
    {:ok, :public_key.pem_decode(pem)}
  rescue
    _error ->
      {:error, :invalid}
  end

  @doc """
  Returns true when the PEM entry is a certificate.
  """
  @spec certificate_entry?(pem_entry()) :: boolean()
  def certificate_entry?({entry_type, _der, _headers}) do
    normalized_pem_label(entry_type) == "certificate"
  end

  @doc """
  Returns true when the PEM entry is some form of private key.
  """
  @spec private_key_entry?(pem_entry()) :: boolean()
  def private_key_entry?({entry_type, _der, _headers}) do
    normalized_pem_label(entry_type)
    |> String.contains?("privatekey")
  end

  @doc """
  Decodes a DER certificate into the requested Erlang/OTP format.

  Returns `{:error, :invalid}` when OTP rejects the DER payload.
  """
  @spec decode_der_certificate(binary(), certificate_format()) ::
          {:ok, tuple()} | {:error, :invalid}
  def decode_der_certificate(der, format \\ :otp) when is_binary(der) do
    {:ok, :public_key.pkix_decode_cert(der, format)}
  rescue
    _error ->
      {:error, :invalid}
  end

  @doc """
  Decodes a list of DER certificates into the `:plain` shape expected by
  `:public_key.pkix_path_validation/3`.
  """
  @spec plain_certificates([binary()]) :: [tuple()]
  def plain_certificates(ders) when is_list(ders) do
    Enum.map(ders, &:public_key.pkix_decode_cert(&1, :plain))
  end

  @doc """
  Encodes a single DER certificate as a PEM block.
  """
  @spec pem_encode(binary()) :: binary()
  def pem_encode(der) when is_binary(der) do
    :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
  end

  @doc """
  Returns true when the decoded OTP certificate has `basicConstraints CA:TRUE`.
  """
  @spec ca_certificate?(tuple()) :: boolean()
  def ca_certificate?(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @basic_constraints_oid) do
      {:Extension, @basic_constraints_oid, _critical, {:BasicConstraints, true, _pathlen}} -> true
      _other -> false
    end
  end

  @doc """
  Returns true when the decoded OTP certificate either omits `Key Usage` or
  explicitly includes `keyCertSign`.
  """
  @spec key_cert_sign_allowed?(tuple()) :: boolean()
  def key_cert_sign_allowed?(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @key_usage_oid) do
      nil -> true
      {:Extension, @key_usage_oid, _critical, usages} -> :keyCertSign in List.wrap(usages)
    end
  end

  @doc """
  Returns the certificate's subject Common Name (CN), or `nil` if absent.
  """
  @spec subject_common_name(tuple()) :: String.t() | nil
  def subject_common_name(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, subject, _spki,
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    common_name(subject)
  end

  @doc """
  Returns the certificate's issuer Common Name (CN), or `nil` if absent.
  """
  @spec issuer_common_name(tuple()) :: String.t() | nil
  def issuer_common_name(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    common_name(issuer)
  end

  @doc """
  Returns the certificate's serial number.
  """
  @spec serial_number(tuple()) :: non_neg_integer()
  def serial_number(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    serial
  end

  @doc """
  Returns the certificate's `notBefore` validity timestamp.
  """
  @spec not_before(tuple()) :: DateTime.t() | nil
  def not_before(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer,
          {:Validity, not_before, _not_after}, _subject, _spki, _issuer_id, _subject_id,
          _extensions}, _sig_alg, _sig}
      ) do
    decode_time(not_before)
  end

  @doc """
  Returns the certificate's `notAfter` validity timestamp (its expiration).
  """
  @spec not_after(tuple()) :: DateTime.t() | nil
  def not_after(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer,
          {:Validity, _not_before, not_after}, _subject, _spki, _issuer_id, _subject_id,
          _extensions}, _sig_alg, _sig}
      ) do
    decode_time(not_after)
  end

  @doc """
  Returns the certificate's X.509 version.
  """
  @spec version(tuple()) :: :v1 | :v2 | :v3
  def version(
        {:OTPCertificate,
         {:OTPTBSCertificate, version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    version
  end

  @doc """
  Returns the certificate's full subject distinguished name, formatted as
  `"CN=..., O=..., C=..."`.
  """
  @spec subject_name(tuple()) :: String.t()
  def subject_name(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, subject, _spki,
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    format_dn(subject)
  end

  @doc """
  Returns the certificate's full issuer distinguished name, formatted as
  `"CN=..., O=..., C=..."`.
  """
  @spec issuer_name(tuple()) :: String.t()
  def issuer_name(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    format_dn(issuer)
  end

  @doc """
  Returns a human-readable name for the algorithm the CA used to sign this
  certificate (e.g. `"sha256WithRSAEncryption"`), falling back to the raw
  dotted-decimal OID for algorithms not in the lookup table.
  """
  @spec signature_algorithm(tuple()) :: String.t()
  def signature_algorithm(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, {:SignatureAlgorithm, oid, _params}, _issuer,
          _validity, _subject, _spki, _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    Map.get(@signature_algorithm_oids, oid, format_oid(oid))
  end

  @doc """
  Returns the certificate's public key algorithm and, where derivable from
  the algorithm itself (RSA modulus size, named EC curve, or the fixed size
  of an EdDSA key), its key size in bits.
  """
  @spec public_key_info(tuple()) :: %{algorithm: String.t(), key_size: pos_integer() | nil}
  def public_key_info(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject,
          {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, alg_oid, alg_params}, key},
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    describe_public_key(alg_oid, alg_params, key)
  end

  @doc """
  Returns the certificate's Basic Constraints extension, or `nil` when the
  extension is absent.
  """
  @spec basic_constraints(tuple()) ::
          %{ca: boolean(), path_length: non_neg_integer() | nil} | nil
  def basic_constraints(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @basic_constraints_oid) do
      {:Extension, @basic_constraints_oid, _critical, {:BasicConstraints, ca?, :asn1_NOVALUE}} ->
        %{ca: ca?, path_length: nil}

      {:Extension, @basic_constraints_oid, _critical, {:BasicConstraints, ca?, path_length}} ->
        %{ca: ca?, path_length: path_length}

      nil ->
        nil
    end
  end

  @doc """
  Returns the certificate's Key Usage flags, or `[]` when the extension is
  absent.
  """
  @spec key_usages(tuple()) :: [atom()]
  def key_usages(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @key_usage_oid) do
      {:Extension, @key_usage_oid, _critical, usages} -> List.wrap(usages)
      nil -> []
    end
  end

  @doc """
  Returns the certificate's Extended Key Usage purposes as human-readable
  names, falling back to the raw dotted-decimal OID for purposes not in the
  lookup table. Returns `[]` when the extension is absent.
  """
  @spec extended_key_usages(tuple()) :: [String.t()]
  def extended_key_usages(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @extended_key_usage_oid) do
      {:Extension, @extended_key_usage_oid, _critical, oids} ->
        Enum.map(List.wrap(oids), &Map.get(@extended_key_usage_oids, &1, format_oid(&1)))

      nil ->
        []
    end
  end

  @doc """
  Returns the certificate's hex-encoded Subject Key Identifier, or `nil`
  when the extension is absent.
  """
  @spec subject_key_identifier(tuple()) :: String.t() | nil
  def subject_key_identifier(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @subject_key_identifier_oid) do
      {:Extension, @subject_key_identifier_oid, _critical, keyid} when is_binary(keyid) ->
        hex_encode(keyid)

      _other ->
        nil
    end
  end

  @doc """
  Returns the certificate's hex-encoded Authority Key Identifier (the
  issuing CA's Subject Key Identifier), or `nil` when the extension is
  absent or omits the key identifier.
  """
  @spec authority_key_identifier(tuple()) :: String.t() | nil
  def authority_key_identifier(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @authority_key_identifier_oid) do
      {:Extension, @authority_key_identifier_oid, _critical,
       {:AuthorityKeyIdentifier, keyid, _issuer, _serial}}
      when is_binary(keyid) ->
        hex_encode(keyid)

      _other ->
        nil
    end
  end

  @doc """
  Returns the certificate's Subject Alternative Names, formatted as
  `"DNS:example.com"` / `"IP:10.0.0.1"`. Returns `[]` when the extension is
  absent.
  """
  @spec subject_alt_names(tuple()) :: [String.t()]
  def subject_alt_names(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @subject_alt_name_oid) do
      {:Extension, @subject_alt_name_oid, _critical, names} ->
        names |> List.wrap() |> Enum.map(&format_general_name/1) |> Enum.reject(&is_nil/1)

      nil ->
        []
    end
  end

  @doc """
  Returns the raw values of the certificate's URI Subject Alternative Names,
  without the `"URI:"` display prefix. Returns `[]` when the extension is
  absent.
  """
  @spec san_uris(tuple()) :: [String.t()]
  def san_uris(otp_certificate) do
    san_general_names(otp_certificate, :uniformResourceIdentifier)
  end

  @doc """
  Returns the raw values of the certificate's DNS Subject Alternative Names,
  without the `"DNS:"` display prefix. Returns `[]` when the extension is
  absent.
  """
  @spec san_dns_names(tuple()) :: [String.t()]
  def san_dns_names(otp_certificate) do
    san_general_names(otp_certificate, :dNSName)
  end

  @doc """
  Returns true when the certificate's Extended Key Usage extension includes
  TLS Client Authentication (`1.3.6.1.5.5.7.3.2`).
  """
  @spec client_auth_eku?(tuple()) :: boolean()
  def client_auth_eku?(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @extended_key_usage_oid) do
      {:Extension, @extended_key_usage_oid, _critical, oids} ->
        @client_auth_eku_oid in List.wrap(oids)

      nil ->
        false
    end
  end

  @doc """
  Returns the certificate's subject public key in the shape expected by
  `:public_key.verify/4`: EC keys are returned as `{point, curve_params}`,
  other keys (RSA, EdDSA) as-is.
  """
  @spec subject_public_key(tuple()) :: {:ok, term()} | :error
  def subject_public_key(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject,
          {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, alg_oid, alg_params}, key},
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    case alg_oid do
      @ec_public_key_oid -> {:ok, {key, alg_params}}
      _other -> {:ok, key}
    end
  end

  def subject_public_key(_other), do: :error

  @doc """
  Returns the message digest to use when verifying a signature made with the
  certificate's subject key: `:sha384` for P-384 EC keys, `:sha256` otherwise.
  """
  @spec verification_digest(tuple()) :: :sha256 | :sha384
  def verification_digest(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject,
          {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @ec_public_key_oid, alg_params}, _key},
          _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    case alg_params do
      {:namedCurve, @p384_curve_oid} -> :sha384
      _other -> :sha256
    end
  end

  def verification_digest(_other), do: :sha256

  @doc """
  Returns the values of the certificate subject's Organizational Unit (OU)
  attributes. Returns `[]` when none are present.
  """
  @spec subject_organizational_units(tuple()) :: [String.t()]
  def subject_organizational_units(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity,
          {:rdnSequence, rdns}, _spki, _issuer_id, _subject_id, _extensions}, _sig_alg, _sig}
      ) do
    rdns
    |> List.flatten()
    |> Enum.flat_map(fn
      {:AttributeTypeAndValue, @organizational_unit_oid, value} ->
        case decode_directory_string(value) do
          nil -> []
          decoded -> [decoded]
        end

      _other ->
        []
    end)
  end

  def subject_organizational_units(_other), do: []

  defp san_general_names(
         {:OTPCertificate,
          {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
           _issuer_id, _subject_id, extensions}, _sig_alg, _sig},
         type
       ) do
    case find_extension(extensions, @subject_alt_name_oid) do
      {:Extension, @subject_alt_name_oid, _critical, names} ->
        names
        |> List.wrap()
        |> Enum.flat_map(fn
          {^type, value} -> [List.to_string(value)]
          _other -> []
        end)

      nil ->
        []
    end
  end

  @doc """
  Returns the certificate's CRL Distribution Point URLs. Returns `[]` when
  the extension is absent or its ASN.1 payload can't be decoded.
  """
  @spec crl_distribution_points(tuple()) :: [String.t()]
  def crl_distribution_points(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @crl_distribution_points_oid) do
      {:Extension, @crl_distribution_points_oid, _critical, der} when is_binary(der) ->
        decode_crl_distribution_points(der)

      _other ->
        []
    end
  end

  @doc """
  Returns the certificate's Authority Information Access URLs, split into
  OCSP responder and CA Issuers URLs. Returns empty lists when the
  extension is absent.
  """
  @spec authority_info_access(tuple()) :: %{ocsp: [String.t()], ca_issuers: [String.t()]}
  def authority_info_access(
        {:OTPCertificate,
         {:OTPTBSCertificate, _version, _serial, _signature, _issuer, _validity, _subject, _spki,
          _issuer_id, _subject_id, extensions}, _sig_alg, _sig}
      ) do
    case find_extension(extensions, @authority_info_access_oid) do
      {:Extension, @authority_info_access_oid, _critical, descriptions} ->
        Enum.reduce(List.wrap(descriptions), %{ocsp: [], ca_issuers: []}, &collect_access_url/2)

      nil ->
        %{ocsp: [], ca_issuers: []}
    end
  end

  defp normalized_pem_label(entry_type) when is_atom(entry_type) do
    entry_type
    |> Atom.to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z]/, "")
  end

  defp find_extension(extensions, oid) do
    extensions = if is_list(extensions), do: extensions, else: []

    Enum.find(extensions, fn
      {:Extension, ^oid, _critical, _value} -> true
      _other -> false
    end)
  end

  defp common_name({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.find_value(fn
      {:AttributeTypeAndValue, @common_name_oid, value} -> decode_directory_string(value)
      _other -> nil
    end)
  end

  defp common_name(_other), do: nil

  defp format_dn({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.map_join(", ", fn {:AttributeTypeAndValue, oid, value} ->
      label = Map.get(@dn_attribute_oids, oid, format_oid(oid))
      "#{label}=#{decode_directory_string(value) || "?"}"
    end)
  end

  defp format_dn(_other), do: ""

  defp format_oid(oid) when is_tuple(oid) do
    oid |> Tuple.to_list() |> Enum.map_join(".", &Integer.to_string/1)
  end

  defp hex_encode(bytes) when is_binary(bytes) do
    bytes
    |> Base.encode16(case: :lower)
    |> String.to_charlist()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &List.to_string/1)
  end

  # RSA key size is the byte-aligned bit length of the modulus.
  defp describe_public_key(
         {1, 2, 840, 113_549, 1, 1, 1},
         _params,
         {:RSAPublicKey, modulus, _exponent}
       ) do
    %{algorithm: "RSA", key_size: byte_size(:binary.encode_unsigned(modulus)) * 8}
  end

  # EC key size is fixed per named curve; the point itself needn't be read.
  defp describe_public_key({1, 2, 840, 10_045, 2, 1}, {:namedCurve, curve_oid}, _key) do
    case Map.get(@ec_curve_oids, curve_oid) do
      {name, size} -> %{algorithm: name, key_size: size}
      nil -> %{algorithm: "EC (#{format_oid(curve_oid)})", key_size: nil}
    end
  end

  defp describe_public_key({1, 3, 101, 112}, _params, _key),
    do: %{algorithm: "Ed25519", key_size: 256}

  defp describe_public_key({1, 3, 101, 113}, _params, _key),
    do: %{algorithm: "Ed448", key_size: 456}

  defp describe_public_key(oid, _params, _key), do: %{algorithm: format_oid(oid), key_size: nil}

  defp decode_crl_distribution_points(der) do
    :CRLDistributionPoints
    |> :public_key.der_decode(der)
    |> Enum.flat_map(&extract_crl_urls/1)
  rescue
    _error -> []
  end

  defp extract_crl_urls({:DistributionPoint, {:fullName, names}, _reason, _issuer}) do
    names |> List.wrap() |> Enum.map(&general_name_uri/1) |> Enum.reject(&is_nil/1)
  end

  defp extract_crl_urls(_other), do: []

  defp collect_access_url({:AccessDescription, @ocsp_access_method_oid, location}, acc) do
    case general_name_uri(location) do
      nil -> acc
      url -> Map.update!(acc, :ocsp, &(&1 ++ [url]))
    end
  end

  defp collect_access_url({:AccessDescription, @ca_issuers_access_method_oid, location}, acc) do
    case general_name_uri(location) do
      nil -> acc
      url -> Map.update!(acc, :ca_issuers, &(&1 ++ [url]))
    end
  end

  defp collect_access_url(_other, acc), do: acc

  defp general_name_uri({:uniformResourceIdentifier, value}), do: List.to_string(value)
  defp general_name_uri(_other), do: nil

  defp format_general_name({:dNSName, value}), do: "DNS:#{List.to_string(value)}"
  defp format_general_name({:rfc822Name, value}), do: "email:#{List.to_string(value)}"
  defp format_general_name({:uniformResourceIdentifier, value}), do: "URI:#{List.to_string(value)}"

  defp format_general_name({:iPAddress, <<a, b, c, d>>}) do
    "IP:" <> List.to_string(:inet.ntoa({a, b, c, d}))
  end

  defp format_general_name(
         {:iPAddress, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}
       ) do
    "IP:" <> List.to_string(:inet.ntoa({a, b, c, d, e, f, g, h}))
  end

  defp format_general_name(_other), do: nil

  defp decode_directory_string({:utf8String, value}) when is_binary(value), do: value
  defp decode_directory_string({:printableString, value}), do: List.to_string(value)
  defp decode_directory_string({:teletexString, value}), do: List.to_string(value)
  defp decode_directory_string({:universalString, value}), do: List.to_string(value)
  defp decode_directory_string({:bmpString, value}), do: List.to_string(value)
  defp decode_directory_string(_other), do: nil

  defp decode_time({:utcTime, value}), do: parse_asn1_time(List.to_string(value), 2)
  defp decode_time({:generalTime, value}), do: parse_asn1_time(List.to_string(value), 4)
  defp decode_time(_other), do: nil

  defp parse_asn1_time(value, year_digits) do
    {year_str, rest} = String.split_at(value, year_digits)
    year = normalize_year(String.to_integer(year_str), year_digits)

    case rest do
      <<month::binary-2, day::binary-2, hour::binary-2, minute::binary-2, second::binary-2,
        "Z">> ->
        DateTime.new!(
          Date.new!(year, String.to_integer(month), String.to_integer(day)),
          Time.new!(String.to_integer(hour), String.to_integer(minute), String.to_integer(second))
        )

      _other ->
        nil
    end
  rescue
    _error -> nil
  end

  defp normalize_year(year, 2) when year < 50, do: 2000 + year
  defp normalize_year(year, 2), do: 1900 + year
  defp normalize_year(year, 4), do: year
end
