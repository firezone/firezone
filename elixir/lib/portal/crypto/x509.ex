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
end
