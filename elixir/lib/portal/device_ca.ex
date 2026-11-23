defmodule Portal.DeviceCA do
  @moduledoc """
  The CA of each account that issues the certificates its devices connect with.
  """
  alias __MODULE__.{Database, KeyVault, Local}
  alias Portal.DeviceCertificateAuthority

  @type key :: %{key_id: String.t(), public_key: {:RSAPublicKey, pos_integer(), pos_integer()}}

  @doc "Creates the account's key, or a new version of it, and returns its public key."
  @callback create_key(account_id :: Ecto.UUID.t()) :: {:ok, key()} | {:error, term()}

  @doc "Signs a SHA-256 digest with the key and returns the RSASSA-PKCS1-v1_5 signature."
  @callback sign(key_id :: String.t(), digest :: binary()) :: {:ok, binary()} | {:error, term()}

  @doc "Deletes the account's key. A key that does not exist is already deleted."
  @callback delete_key(account_id :: Ecto.UUID.t()) :: :ok | {:error, term()}

  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @sha256_with_rsa {:SignatureAlgorithm, {1, 2, 840, 113_549, 1, 1, 11}, :asn1_NOVALUE}
  @signature_size 256
  @common_name {2, 5, 4, 3}
  @organization {2, 5, 4, 10}
  @basic_constraints {2, 5, 29, 19}
  @key_usage {2, 5, 29, 15}
  @subject_key_identifier {2, 5, 29, 14}
  @ca_lifetime_days 20 * 365

  @doc "The account's CA, created with its key the first time it is asked for."
  @spec ensure(Ecto.UUID.t()) :: {:ok, DeviceCertificateAuthority.t()} | {:error, term()}
  def ensure(account_id) do
    case Database.fetch(account_id) do
      %DeviceCertificateAuthority{} = ca -> {:ok, ca}
      nil -> create(account_id)
    end
  end

  @doc "Deletes the key of a deleted account. Its CA row went with the account."
  @spec delete_key(Ecto.UUID.t()) :: :ok | {:error, term()}
  def delete_key(account_id), do: adapter().delete_key(account_id)

  @spec adapter() :: module()
  def adapter do
    case Portal.Config.fetch_env!(:portal, :device_ca_key_vault_url) do
      nil -> Local
      _vault_url -> KeyVault
    end
  end

  # A racing create loses the insert and returns the CA that won. Its key version stays unused.
  defp create(account_id) do
    with {:ok, %{key_id: key_id, public_key: public_key}} <- adapter().create_key(account_id),
         {:ok, certificate} <- self_signed_certificate(account_id, key_id, public_key) do
      Database.insert(account_id, key_id, certificate)
    end
  end

  defp self_signed_certificate(account_id, key_id, public_key) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    name = ca_name(account_id)

    tbs =
      {:OTPTBSCertificate, :v3, serial_number(), @sha256_with_rsa, name,
       {:Validity, x509_time(now), x509_time(DateTime.add(now, @ca_lifetime_days, :day))}, name,
       {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @rsa_encryption, :asn1_NOVALUE}, public_key},
       :asn1_NOVALUE, :asn1_NOVALUE,
       [
         {:Extension, @basic_constraints, true, {:BasicConstraints, true, 0}},
         {:Extension, @key_usage, true, [:keyCertSign, :cRLSign]},
         {:Extension, @subject_key_identifier, false, key_identifier(public_key)}
       ]}

    tbs_der = :public_key.pkix_encode(:OTPTBSCertificate, tbs, :otp)

    with {:ok, <<_::binary-size(@signature_size)>> = signature} <-
           adapter().sign(key_id, :crypto.hash(:sha256, tbs_der)) do
      {:ok, :public_key.pkix_encode(:OTPCertificate, {:OTPCertificate, tbs, @sha256_with_rsa, signature}, :otp)}
    end
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
  defp key_identifier(public_key),
    do: binary_part(:crypto.hash(:sha256, :public_key.der_encode(:RSAPublicKey, public_key)), 0, 20)

  # Positive and within the 20 octets RFC 5280 allows.
  defp serial_number, do: :binary.decode_unsigned(:crypto.strong_rand_bytes(19)) + 1

  defmodule Database do
    import Ecto.Query
    alias Portal.{DeviceCertificateAuthority, Safe}

    def fetch(account_id) do
      from(ca in DeviceCertificateAuthority, where: ca.account_id == ^account_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def insert(account_id, key_id, certificate) do
      %DeviceCertificateAuthority{}
      |> Ecto.Changeset.change(account_id: account_id, key_id: key_id, certificate: certificate)
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
