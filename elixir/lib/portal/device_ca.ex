defmodule Portal.DeviceCA do
  @moduledoc """
  The CA of each account that issues the certificates its devices connect with.
  """
  alias __MODULE__.{Database, KeyVault, Local}
  alias Portal.DeviceCertificateAuthority

  @type key :: %{key_id: String.t() | nil, private_key: binary() | nil}
  @type new_key :: %{
          key_id: String.t() | nil,
          private_key: binary() | nil,
          public_key: public_key()
        }
  @type public_key :: {{:ECPoint, binary()}, {:namedCurve, tuple()}}

  @doc "Creates the account's key, or a new version of it, and returns it with its public key."
  @callback create_key(account_id :: Ecto.UUID.t()) :: {:ok, new_key()} | {:error, term()}

  @doc "Signs a SHA-256 digest with the key and returns the DER ECDSA signature."
  @callback sign(key :: key(), digest :: binary()) :: {:ok, binary()} | {:error, term()}

  @doc "Deletes the account's key. A key that does not exist is already deleted."
  @callback delete_key(account_id :: Ecto.UUID.t()) :: :ok | {:error, term()}

  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @p256 {:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}}
  @ecdsa_with_sha256_oid {1, 2, 840, 10_045, 4, 3, 2}
  @ecdsa_with_sha256 {:SignatureAlgorithm, @ecdsa_with_sha256_oid, :asn1_NOVALUE}
  @common_name {2, 5, 4, 3}
  @organization {2, 5, 4, 10}
  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @subject_key_identifier {2, 5, 29, 14}
  @authority_key_identifier {2, 5, 29, 35}
  @extended_key_usage {2, 5, 29, 37}
  @client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @ca_lifetime_days 20 * 365
  @device_lifetime_days 90
  # A device clock that runs a little behind still accepts a new certificate.
  @clock_skew_seconds 5 * 60

  @doc "The account's CA, created with its key the first time it is asked for."
  @spec ensure(Ecto.UUID.t()) :: {:ok, DeviceCertificateAuthority.t()} | {:error, term()}
  def ensure(account_id) do
    case {Database.fetch(account_id), adapter()} do
      {%DeviceCertificateAuthority{} = ca, _adapter} -> with_trust_anchor(ca)
      {nil, nil} -> {:error, :no_key_storage}
      {nil, adapter} -> with {:ok, ca} <- create(adapter, account_id), do: with_trust_anchor(ca)
    end
  end

  @doc "The name of the system trust anchor that holds the account's CA certificate."
  def trust_anchor_name, do: "Firezone device CA"

  # The CA shows as the account's system trust anchor. CAs made before that get it here.
  defp with_trust_anchor(%DeviceCertificateAuthority{} = ca) do
    if Database.trust_anchor?(ca.account_id) do
      {:ok, ca}
    else
      with {:ok, _trust_anchor} <- Database.insert_trust_anchor(ca), do: {:ok, ca}
    end
  end

  @doc "Deletes the key of a deleted account. Its CA row went with the account."
  @spec delete_key(Ecto.UUID.t()) :: :ok | {:error, term()}
  def delete_key(account_id) do
    case adapter() do
      nil -> :ok
      adapter -> adapter.delete_key(account_id)
    end
  end

  @doc """
  Issues a device certificate for the P-256 key in a CSR, signed by the account's CA. Returns
  the certificate with the hash of the key, which the device row stores.
  """
  @spec issue(Ecto.UUID.t(), Ecto.UUID.t(), binary()) ::
          {:ok, %{certificate: binary(), key_hash: binary()}} | {:error, term()}
  def issue(account_id, device_id, csr) do
    with {:ok, point} <- csr_public_point(csr),
         {:ok, ca} <- ensure(account_id),
         {:ok, adapter} <- fetch_adapter(),
         {:ok, certificate} <- device_certificate(adapter, ca, device_id, point) do
      {:ok, %{certificate: certificate, key_hash: key_hash(point)}}
    end
  end

  @doc "The hash that identifies a device by its P-256 public point."
  @spec key_hash(binary()) :: binary()
  def key_hash(point), do: :crypto.hash(:sha256, point)

  @doc "True when DEVICE_CA_KEY_STORAGE is set."
  @spec enabled?() :: boolean()
  def enabled?, do: adapter() != nil

  defp fetch_adapter do
    case adapter() do
      nil -> {:error, :no_key_storage}
      adapter -> {:ok, adapter}
    end
  end

  defp adapter do
    case Portal.Config.fetch_env!(:portal, :device_ca_key_storage) do
      :db -> Local
      :azure -> KeyVault
      nil -> nil
    end
  end

  # A racing create loses the insert and returns the CA that won. Its key stays unused.
  # A failed insert means the account is gone, so its new key goes too.
  defp create(adapter, account_id) do
    with {:ok, %{public_key: public_key} = key} <- adapter.create_key(account_id),
         {:ok, certificate} <- self_signed_certificate(adapter, account_id, key, public_key) do
      case Database.insert(account_id, key, certificate) do
        {:ok, ca} ->
          {:ok, ca}

        {:error, _reason} = error ->
          _ = adapter.delete_key(account_id)
          error
      end
    end
  end

  defp self_signed_certificate(adapter, account_id, key, {{:ECPoint, point}, @p256} = public_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    name = ca_name(account_id)

    tbs =
      {:OTPTBSCertificate, :v3, serial_number(), @ecdsa_with_sha256, name,
       {:Validity, x509_time(now), x509_time(DateTime.add(now, @ca_lifetime_days, :day))}, name,
       {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @ec_public_key, @p256}, {:ECPoint, point}},
       :asn1_NOVALUE, :asn1_NOVALUE,
       [
         {:Extension, @basic_constraints, true, {:BasicConstraints, true, 0}},
         {:Extension, @key_usage, true, [:keyCertSign, :cRLSign]},
         {:Extension, @subject_key_identifier, false, key_identifier(point)}
       ]}

    digest = :crypto.hash(:sha256, :public_key.pkix_encode(:OTPTBSCertificate, tbs, :otp))

    with {:ok, signature} <- adapter.sign(key, digest),
         :ok <- verify(digest, signature, public_key) do
      {:ok, :public_key.pkix_encode(:OTPCertificate, {:OTPCertificate, tbs, @ecdsa_with_sha256, signature}, :otp)}
    end
  end

  defp self_signed_certificate(_adapter, _account_id, _key, _public_key), do: {:error, :unsupported_key}

  defp device_certificate(adapter, ca, device_id, point) do
    {:OTPCertificate, {:OTPTBSCertificate, _, _, _, _, _, ca_name, ca_key_info, _, _, _}, _, _} =
      :public_key.pkix_decode_cert(ca.certificate, :otp)

    {:OTPSubjectPublicKeyInfo, _algorithm, {:ECPoint, ca_point}} = ca_key_info
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    tbs =
      {:OTPTBSCertificate, :v3, serial_number(), @ecdsa_with_sha256, ca_name,
       {:Validity, x509_time(DateTime.add(now, -@clock_skew_seconds)),
        x509_time(DateTime.add(now, @device_lifetime_days, :day))},
       {:rdnSequence, [[{:AttributeTypeAndValue, @common_name, {:utf8String, device_id}}]]},
       {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @ec_public_key, @p256}, {:ECPoint, point}},
       :asn1_NOVALUE, :asn1_NOVALUE,
       [
         {:Extension, @basic_constraints, true, {:BasicConstraints, false, :asn1_NOVALUE}},
         {:Extension, @key_usage, true, [:digitalSignature]},
         {:Extension, @extended_key_usage, false, [@client_auth]},
         {:Extension, @subject_key_identifier, false, key_identifier(point)},
         {:Extension, @authority_key_identifier, false,
          {:AuthorityKeyIdentifier, key_identifier(ca_point), :asn1_NOVALUE, :asn1_NOVALUE}}
       ]}

    digest = :crypto.hash(:sha256, :public_key.pkix_encode(:OTPTBSCertificate, tbs, :otp))
    key = %{key_id: ca.key_id, private_key: ca.private_key}

    with {:ok, signature} <- adapter.sign(key, digest),
         :ok <- verify(digest, signature, {{:ECPoint, ca_point}, @p256}) do
      {:ok, :public_key.pkix_encode(:OTPCertificate, {:OTPCertificate, tbs, @ecdsa_with_sha256, signature}, :otp)}
    end
  end

  # The CSR proves the device holds the key. Only P-256 keys signed with SHA-256 are accepted.
  defp csr_public_point(csr) do
    {:CertificationRequest, info, {_, signature_algorithm, _}, signature} =
      :public_key.der_decode(:CertificationRequest, csr)

    {:CertificationRequestInfo, _version, _subject,
     {_, {_, key_algorithm, {:asn1_OPENTYPE, parameters}}, point}, _attributes} = info

    curve = :public_key.der_decode(:EcpkParameters, parameters)
    signed_info = :public_key.der_encode(:CertificationRequestInfo, info)

    cond do
      {key_algorithm, curve, signature_algorithm} != {@ec_public_key, @p256, @ecdsa_with_sha256_oid} ->
        {:error, :unsupported_key}

      match?(<<4, _xy::binary-size(64)>>, point) and
          :public_key.verify(signed_info, :sha256, signature, {{:ECPoint, point}, @p256}) ->
        {:ok, point}

      true ->
        {:error, :invalid_csr}
    end
  rescue
    _exception -> {:error, :invalid_csr}
  end

  defp verify(digest, signature, public_key) do
    if :public_key.verify({:digest, digest}, :sha256, signature, public_key),
      do: :ok,
      else: {:error, :bad_signature}
  end

  defp ca_name(account_id) do
    {:rdnSequence,
     [
       [{:AttributeTypeAndValue, @organization, {:utf8String, "Firezone"}}],
       [{:AttributeTypeAndValue, @common_name, {:utf8String, "Firezone device CA " <> account_id}}]
     ]}
  end

  # RFC 5280: UTCTime through 2049, GeneralizedTime after.
  defp x509_time(%DateTime{year: year} = datetime) when year < 2050,
    do: {:utcTime, datetime |> Calendar.strftime("%y%m%d%H%M%SZ") |> String.to_charlist()}

  defp x509_time(datetime),
    do: {:generalTime, datetime |> Calendar.strftime("%Y%m%d%H%M%SZ") |> String.to_charlist()}

  # RFC 7093 method 1: the leftmost 160 bits of the SHA-256 of the public key.
  defp key_identifier(point), do: binary_part(:crypto.hash(:sha256, point), 0, 20)

  # Positive and within the 20 octets RFC 5280 allows.
  defp serial_number, do: :binary.decode_unsigned(:crypto.strong_rand_bytes(19)) + 1

  defmodule Database do
    import Ecto.Query
    alias Portal.{DeviceCertificateAuthority, Safe, TrustAnchor}

    def trust_anchor?(account_id) do
      from(t in TrustAnchor, where: t.account_id == ^account_id and t.system)
      |> Safe.unscoped()
      |> Safe.exists?()
    end

    # A racing insert loses on the one-per-account index and finds the winner's anchor.
    def insert_trust_anchor(%DeviceCertificateAuthority{} = ca) do
      %TrustAnchor{}
      |> Ecto.Changeset.change(
        account_id: ca.account_id,
        name: Portal.DeviceCA.trust_anchor_name(),
        system: true,
        certs: [ca.certificate]
      )
      |> TrustAnchor.changeset()
      |> Ecto.Changeset.unique_constraint(:account_id, name: :trust_anchors_account_id_system_index)
      |> Safe.unscoped()
      |> Safe.insert()
      |> case do
        {:ok, trust_anchor} ->
          {:ok, trust_anchor}

        {:error, %Ecto.Changeset{errors: errors} = changeset} ->
          if Keyword.has_key?(errors, :account_id) and trust_anchor?(ca.account_id),
            do: {:ok, :exists},
            else: {:error, changeset}
      end
    end

    def fetch(account_id) do
      from(ca in DeviceCertificateAuthority, where: ca.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def insert(account_id, key, certificate) do
      %DeviceCertificateAuthority{}
      |> Ecto.Changeset.change(
        account_id: account_id,
        key_id: key.key_id,
        private_key: key.private_key,
        certificate: certificate
      )
      |> DeviceCertificateAuthority.changeset()
      |> Safe.unscoped()
      |> Safe.insert(on_conflict: :nothing, conflict_target: [:account_id])
      |> case do
        {:ok, %DeviceCertificateAuthority{}} -> fetch_inserted(account_id)
        {:error, _changeset} = error -> error
      end
    end

    defp fetch_inserted(account_id) do
      case fetch(account_id) do
        %DeviceCertificateAuthority{} = ca -> {:ok, ca}
        nil -> {:error, :not_found}
      end
    end
  end
end
