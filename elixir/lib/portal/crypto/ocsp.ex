defmodule Portal.Crypto.Ocsp do
  @moduledoc """
  Builds Online Certificate Status Protocol requests and reads the responses.

  A CRL answers for a whole CA at once. OCSP answers one certificate at a time,
  so a question names the certificate by the hash of its issuer's name, the hash
  of its issuer's key, and its serial. Nothing about the certificate itself is
  sent, which is why the issuing CA's certificate has to be on hand to ask.

  No nonce is sent. RFC 5019's lightweight profile drops it so responses stay
  cacheable, high volume responders ignore or reject it, and the freshness bound
  here is the response's own `nextUpdate` in any case.
  """

  # RFC 6960 fixes SHA-1 as the CertID digest. It identifies which certificate
  # is being asked about rather than authenticating anything, so its weakness
  # does not carry: the answer's own signature is what is trusted.
  @sha1_oid {1, 3, 14, 3, 2, 26}
  @basic_response_oid {1, 3, 6, 1, 5, 5, 7, 48, 1, 1}
  @ocsp_signing_oid {1, 3, 6, 1, 5, 5, 7, 3, 9}
  @extended_key_usage_oid {2, 5, 29, 37}

  @type status :: %{
          status: :good | :revoked,
          revoked_at: DateTime.t() | nil,
          reason: String.t() | nil,
          produced_at: DateTime.t() | nil,
          this_update: DateTime.t() | nil,
          next_update: DateTime.t() | nil
        }

  @doc """
  Builds a request asking one issuer about one serial.

  `issuer_der` is the CA certificate, needed for the hash of its key, and
  `serial` is uppercase hex as the device rows record it.
  """
  @spec build_request(binary(), String.t()) :: {:ok, binary()} | {:error, :invalid}
  def build_request(issuer_der, serial) when is_binary(issuer_der) and is_binary(serial) do
    with {:ok, cert_id} <- cert_id(issuer_der, serial) do
      tbs = {:TBSRequest, :v1, :asn1_NOVALUE, [{:Request, cert_id, :asn1_NOVALUE}], :asn1_NOVALUE}
      {:ok, :public_key.der_encode(:OCSPRequest, {:OCSPRequest, tbs, :asn1_NOVALUE})}
    end
  rescue
    _error -> {:error, :invalid}
  end

  @doc """
  Reads a response and returns what it says about `serial`.

  The answer is only believed when it is signed either by the CA itself or by a
  responder the CA delegated to, which means a certificate the CA issued that
  carries the OCSP signing extended key usage. Anything else answering the
  address could otherwise clear a revoked certificate.

  `:unknown` is returned as an error rather than a status: the responder is
  saying it has no record of a certificate our own anchor issued, which means
  the question was built wrong or was sent to a responder that does not serve
  this CA.
  """
  @spec read_response(binary(), binary(), String.t()) ::
          {:ok, status()}
          | {:error,
             :invalid | :unsuccessful | :untrusted_signer | :no_answer | :unknown_certificate}
  def read_response(response_der, issuer_der, serial) do
    with {:ok, basic} <- basic_response(response_der),
         {:ResponseData, _v, _id, produced_at, responses, _ext} = tbs <- elem(basic, 1),
         :ok <- verify_signature(basic, tbs, issuer_der),
         {:ok, cert_id} <- cert_id(issuer_der, serial),
         {:ok, single} <- find_response(responses, cert_id) do
      read_single(single, produced_at)
    end
  rescue
    _error -> {:error, :invalid}
  end

  defp basic_response(der) do
    case :public_key.der_decode(:OCSPResponse, der) do
      {:OCSPResponse, :successful, {:ResponseBytes, @basic_response_oid, bytes}} ->
        {:ok, :public_key.der_decode(:BasicOCSPResponse, bytes)}

      _other ->
        {:error, :unsuccessful}
    end
  end

  defp read_single({:SingleResponse, _id, status, this_update, next_update, _ext}, produced_at) do
    case status do
      {:good, _} ->
        {:ok,
         %{
           status: :good,
           revoked_at: nil,
           reason: nil,
           produced_at: decode_time(produced_at),
           this_update: decode_time(this_update),
           next_update: decode_time(next_update)
         }}

      {:revoked, {:RevokedInfo, revoked_at, reason}} ->
        {:ok,
         %{
           status: :revoked,
           revoked_at: decode_time(revoked_at),
           reason: decode_reason(reason),
           produced_at: decode_time(produced_at),
           this_update: decode_time(this_update),
           next_update: decode_time(next_update)
         }}

      {:unknown, _} ->
        {:error, :unknown_certificate}
    end
  end

  defp find_response(responses, cert_id) do
    case Enum.find(responses, &(elem(&1, 1) == cert_id)) do
      nil -> {:error, :no_answer}
      single -> {:ok, single}
    end
  end

  # The CA may answer directly, or delegate to a responder it issued a
  # certificate to for exactly this purpose. Only those two are accepted.
  defp verify_signature({:BasicOCSPResponse, _tbs, algorithm, signature, certs}, tbs, issuer_der) do
    tbs_der = :public_key.der_encode(:ResponseData, tbs)
    {digest, _type} = :public_key.pkix_sign_types(elem(algorithm, 1))

    issuer_der
    |> signer_candidates(certs)
    |> Enum.any?(fn candidate ->
      :public_key.verify(tbs_der, digest, signature, public_key(candidate))
    end)
    |> case do
      true -> :ok
      false -> {:error, :untrusted_signer}
    end
  end

  defp signer_candidates(issuer_der, certs) do
    delegated =
      certs
      |> List.wrap()
      |> Enum.reject(&(&1 == :asn1_NOVALUE))
      |> Enum.map(&:public_key.der_encode(:Certificate, &1))
      |> Enum.filter(&delegated_responder?(&1, issuer_der))

    [issuer_der | delegated]
  end

  # A delegation that has expired is no delegation. Without this a retired
  # responder key would go on authoritatively clearing certificates.
  defp delegated_responder?(candidate_der, issuer_der) do
    ocsp_signing?(candidate_der) and within_validity?(candidate_der) and
      issued_by?(candidate_der, issuer_der)
  end

  defp within_validity?(der) do
    otp_cert = :public_key.pkix_decode_cert(der, :otp)
    now = DateTime.utc_now()
    not_before = Portal.Crypto.X509.not_before(otp_cert)
    not_after = Portal.Crypto.X509.not_after(otp_cert)

    not is_nil(not_before) and not is_nil(not_after) and
      DateTime.compare(now, not_before) != :lt and DateTime.compare(now, not_after) != :gt
  rescue
    _error -> false
  end

  defp ocsp_signing?(der) do
    {:Certificate, tbs, _algorithm, _signature} = :public_key.der_decode(:Certificate, der)

    tbs
    |> elem(10)
    |> List.wrap()
    |> Enum.any?(fn
      {:Extension, @extended_key_usage_oid, _critical, value} ->
        @ocsp_signing_oid in :public_key.der_decode(:ExtKeyUsageSyntax, value)

      _other ->
        false
    end)
  rescue
    _error -> false
  end

  defp issued_by?(candidate_der, issuer_der) do
    candidate = :public_key.pkix_decode_cert(candidate_der, :otp)
    issuer = :public_key.pkix_decode_cert(issuer_der, :otp)

    :public_key.pkix_is_issuer(candidate, issuer) and
      :public_key.pkix_verify(candidate_der, otp_public_key(issuer))
  rescue
    _error -> false
  end

  defp public_key(der) do
    der |> :public_key.pkix_decode_cert(:otp) |> otp_public_key()
  end

  # An EC key is only usable for verification together with its curve, which
  # sits in the algorithm parameters rather than beside the point.
  defp otp_public_key(otp_cert) do
    spki = otp_cert |> elem(1) |> elem(7)

    case elem(spki, 2) do
      {:ECPoint, _point} = point -> {point, spki |> elem(1) |> elem(2)}
      key -> key
    end
  end

  defp cert_id(issuer_der, serial) do
    {:Certificate, tbs, _algorithm, _signature} =
      :public_key.der_decode(:Certificate, issuer_der)

    name_hash = tbs |> elem(6) |> then(&:public_key.der_encode(:Name, &1)) |> sha1()
    key_hash = tbs |> elem(7) |> elem(2) |> sha1()
    algorithm = {:CertID_hashAlgorithm, @sha1_oid, {:asn1_OPENTYPE, <<5, 0>>}}

    {:ok, {:CertID, algorithm, name_hash, key_hash, String.to_integer(serial, 16)}}
  rescue
    _error -> {:error, :invalid}
  end

  defp sha1(bytes), do: :crypto.hash(:sha, bytes)

  # OCSP timestamps are GeneralizedTime, always four-digit year and always UTC,
  # so they arrive as bare characters rather than the tagged choice a
  # certificate's validity carries.
  defp decode_time(:asn1_NOVALUE), do: nil

  defp decode_time(time) when is_list(time), do: time |> List.to_string() |> decode_time()

  defp decode_time(<<year::binary-4, month::binary-2, day::binary-2, hour::binary-2,
                     minute::binary-2, second::binary-2, "Z">>) do
    with {:ok, date} <- Date.new(int(year), int(month), int(day)),
         {:ok, time} <- Time.new(int(hour), int(minute), int(second)) do
      DateTime.new!(date, time)
    else
      _other -> nil
    end
  end

  defp decode_time(_other), do: nil

  defp int(value), do: String.to_integer(value)

  defp decode_reason(:asn1_NOVALUE), do: nil
  defp decode_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp decode_reason(_other), do: nil
end
