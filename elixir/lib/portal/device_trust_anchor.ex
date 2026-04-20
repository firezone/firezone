defmodule Portal.DeviceTrustAnchor do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset, only: [trim_change: 2]

  alias Portal.Crypto.X509

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  # Reject obviously bad inputs before attempting ASN.1/X.509 decoding. The
  # lower bound filters out trivial garbage, while the upper bound keeps a
  # single uploaded certificate from consuming excessive memory or CPU.
  @cert_min_bytes 64
  @cert_max_bytes 16_384

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          name: String.t(),
          certs: [binary()],
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "device_trust_anchors" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :name, :string

    # CA bundle members are stored as raw DER to minimize work on read during
    # certificate path validation. DER is the canonical binary form of X.509,
    # so uploads can be normalized once at write time instead of re-parsing PEM
    # or base64 wrappers every time a device certificate is validated.
    field :certs, {:array, :binary}, default: []

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> trim_change(:name)
    |> validate_required([:name])
    |> validate_length(:name, min: 3, max: 64)
    |> normalize_certs(:certs)
    |> validate_cert_presence(:certs)
    |> unique_constraint(:name, name: :device_trust_anchors_account_id_name_index)
    |> assoc_constraint(:account)
  end

  defp validate_cert_presence(changeset, field) do
    if field_has_errors?(changeset, field) do
      changeset
    else
      case get_field(changeset, field, []) do
        certs when is_list(certs) and certs != [] ->
          changeset

        _other ->
          add_error(changeset, field, "must contain at least one CA certificate")
      end
    end
  end

  defp normalize_certs(changeset, field) do
    case {field_has_errors?(changeset, field), fetch_change(changeset, field)} do
      {true, _field_value} ->
        changeset

      {false, {:ok, values}} when is_list(values) ->
        values
        |> normalize_certificates()
        |> apply_normalize_certs_result(changeset, field)

      {false, _other} ->
        changeset
    end
  end

  defp normalize_certificates(values) do
    with {:ok, certs} <-
           Enum.reduce_while(values, {:ok, []}, &normalize_certificates_from_value/2) do
      {:ok, Enum.uniq(certs)}
    end
  end

  defp normalize_certificates_from_value(value, {:ok, certs}) when is_binary(value) do
    case normalize_certificates_from_value(value) do
      {:ok, normalized_certs} -> {:cont, {:ok, certs ++ normalized_certs}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_certificates_from_value(_value, {:ok, _certs}) do
    {:halt, {:error, :invalid}}
  end

  defp normalize_certificates_from_value(value) when is_binary(value) do
    value = maybe_trim_string(value)

    cond do
      value == "" ->
        {:ok, []}

      X509.pem_encoded?(value) ->
        normalize_pem_certificates(value)

      String.valid?(value) ->
        normalize_base64_or_der_certificate(value)

      true ->
        normalize_der_certificate(value)
    end
  end

  defp normalize_pem_certificates(pem) do
    with {:ok, entries} <- X509.pem_decode(pem) do
      entries
      |> classify_pem_entries()
      |> apply_pem_entries_result()
    end
  end

  defp normalize_base64_or_der_certificate(value) do
    case Base.decode64(value, ignore: :whitespace) do
      {:ok, der} -> normalize_der_certificate(der)
      :error -> normalize_der_certificate(value)
    end
  end

  defp normalize_der_certificate(der) when is_binary(der) do
    with :ok <- validate_cert_byte_length(der),
         {:ok, otp_cert} <- X509.decode_der_certificate(der),
         :ok <- validate_ca_certificate(otp_cert) do
      {:ok, [der]}
    end
  end

  defp normalize_der_certificates(ders) do
    Enum.reduce_while(ders, {:ok, []}, fn der, {:ok, certs} ->
      case normalize_der_certificate(der) do
        {:ok, [cert]} -> {:cont, {:ok, certs ++ [cert]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_cert_byte_length(der) when is_binary(der) do
    cond do
      byte_size(der) < @cert_min_bytes -> {:error, :too_small}
      byte_size(der) > @cert_max_bytes -> {:error, :too_large}
      true -> :ok
    end
  end

  defp classify_pem_entries(entries) do
    cert_entries = Enum.filter(entries, &X509.certificate_entry?/1)

    cond do
      entries == [] ->
        {:error, :invalid}

      Enum.any?(entries, &X509.private_key_entry?/1) ->
        {:error, :private_key}

      cert_entries == [] ->
        {:error, :invalid}

      # A trust anchor upload must contain certificates only. Reject mixed PEM
      # bundles so we never silently ignore extra material like CSRs or keys.
      length(cert_entries) != length(entries) ->
        {:error, :non_certificate_pem_entry}

      true ->
        {:ok, cert_entries}
    end
  end

  defp apply_pem_entries_result({:ok, cert_entries}) do
    cert_entries
    |> Enum.map(fn {_entry_type, der, _headers} -> der end)
    |> normalize_der_certificates()
  end

  defp apply_pem_entries_result({:error, reason}), do: {:error, reason}

  defp validate_ca_certificate(otp_cert) do
    # Upload-time validation is intentionally narrow: every stored certificate
    # must be a CA, and if Key Usage is present it must permit certificate
    # signing. Leaf-specific checks such as clientAuth belong in the runtime
    # validation path for the device-presented certificate, not in trust anchor
    # ingestion.
    with true <- X509.ca_certificate?(otp_cert) or {:error, :not_ca},
         true <- X509.key_cert_sign_allowed?(otp_cert) or {:error, :missing_key_cert_sign} do
      :ok
    end
  end

  defp apply_normalize_certs_result({:ok, normalized_certs}, changeset, field) do
    put_change(changeset, field, normalized_certs)
  end

  defp apply_normalize_certs_result({:error, :not_ca}, changeset, field) do
    add_error(changeset, field, "all certificates must be CA certificates")
  end

  defp apply_normalize_certs_result({:error, :missing_key_cert_sign}, changeset, field) do
    add_error(changeset, field, "all CA certificates must allow certificate signing")
  end

  defp apply_normalize_certs_result({:error, reason}, changeset, field)
       when reason in [:private_key, :non_certificate_pem_entry, :too_small, :too_large, :invalid] do
    add_error(changeset, field, "invalid certificate")
  end

  defp maybe_trim_string(value) when is_binary(value) do
    if String.valid?(value), do: String.trim(value), else: value
  end

  defp field_has_errors?(changeset, field) do
    Keyword.has_key?(changeset.errors, field)
  end
end
