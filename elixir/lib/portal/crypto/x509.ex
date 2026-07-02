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
