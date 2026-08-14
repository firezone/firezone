defmodule Portal.Crypto.WebAuthn do
  @moduledoc """
  Dependency-free WebAuthn registration and assertion verification for the
  Firezone Support passkey flow, built on `:crypto`/`:public_key` and a minimal
  CBOR decoder.

  Attestation statements are deliberately not verified (equivalent to
  requesting attestation "none"): trust comes from the emailed registration
  link plus the email OTP at sign-in, not from authenticator provenance.
  Supports ES256 (P-256) and RS256 credentials.
  """

  alias Portal.Crypto.CBOR

  defmodule Challenge do
    @type t :: %__MODULE__{}

    defstruct [:type, :bytes, :origin, :rp_id, :issued_at, allow_credentials: []]
  end

  @challenge_lifetime_secs 900

  @flag_user_present 0x01
  @flag_user_verified 0x04
  @flag_backup_eligible 0x08
  @flag_backed_up 0x10
  @flag_attested_credential_data 0x40

  @max_credential_id_bytes 1023

  @es256_alg -7
  @rs256_alg -257

  def origin do
    PortalWeb.Endpoint.url()
  end

  def rp_id do
    URI.parse(origin()).host
  end

  def registration_challenge do
    new_challenge(:registration, [])
  end

  def authentication_challenge(credential_id, cose_key) do
    new_challenge(:authentication, [{credential_id, cose_key}])
  end

  def verify_registration(%Challenge{type: :registration} = challenge, attestation_object, client_data_json) do
    with :ok <- check_freshness(challenge),
         :ok <- check_client_data(client_data_json, "webauthn.create", challenge),
         {:ok, %{"authData" => auth_data}, _rest} when is_binary(auth_data) <-
           CBOR.decode(attestation_object),
         {:ok, flags, sign_count, attested_data} <- parse_auth_data(auth_data, challenge.rp_id),
         :ok <- check_flag(flags, @flag_user_present),
         :ok <- check_flag(flags, @flag_user_verified),
         :ok <- check_flag(flags, @flag_attested_credential_data),
         :ok <- check_backup_flags(flags),
         {:ok, credential_id, cose_key} <- parse_attested_credential_data(attested_data),
         :ok <- validate_cose_key(cose_key) do
      {:ok,
       %{
         credential_id: credential_id,
         public_key: encode_cose_key(cose_key),
         sign_count: sign_count
       }}
    else
      _error -> {:error, :invalid_registration}
    end
  end

  def verify_authentication(
        credential_id,
        authenticator_data,
        signature,
        client_data_json,
        %Challenge{type: :authentication} = challenge
      ) do
    with :ok <- check_freshness(challenge),
         {:ok, cose_key} <- find_credential(challenge.allow_credentials, credential_id),
         :ok <- check_client_data(client_data_json, "webauthn.get", challenge),
         {:ok, flags, sign_count, _rest} <- parse_auth_data(authenticator_data, challenge.rp_id),
         :ok <- check_flag(flags, @flag_user_present),
         :ok <- check_flag(flags, @flag_user_verified),
         :ok <- check_backup_flags(flags),
         :ok <-
           verify_signature(
             cose_key,
             authenticator_data <> :crypto.hash(:sha256, client_data_json),
             signature
           ) do
      {:ok, %{sign_count: sign_count}}
    else
      _error -> {:error, :invalid_assertion}
    end
  end

  def encode_cose_key(cose_key), do: :erlang.term_to_binary(cose_key)

  def decode_cose_key(binary) when is_binary(binary) do
    Plug.Crypto.non_executable_binary_to_term(binary, [:safe])
  end

  defp new_challenge(type, allow_credentials) do
    %Challenge{
      type: type,
      bytes: :crypto.strong_rand_bytes(32),
      origin: origin(),
      rp_id: rp_id(),
      issued_at: System.system_time(:second),
      allow_credentials: allow_credentials
    }
  end

  defp check_freshness(%Challenge{issued_at: issued_at}) do
    if System.system_time(:second) - issued_at < @challenge_lifetime_secs do
      :ok
    else
      {:error, :expired_challenge}
    end
  end

  defp check_client_data(client_data_json, expected_type, challenge) do
    with {:ok, client_data} <- JSON.decode(client_data_json),
         %{"type" => ^expected_type, "challenge" => challenge_b64, "origin" => origin} <-
           client_data,
         :ok <- check_same_origin(client_data),
         {:ok, challenge_bytes} <- Base.url_decode64(challenge_b64, padding: false),
         true <- challenge_bytes == challenge.bytes,
         true <- origin == challenge.origin do
      :ok
    else
      _error -> {:error, :invalid_client_data}
    end
  end

  defp check_same_origin(%{"crossOrigin" => true}), do: {:error, :cross_origin}
  defp check_same_origin(%{"topOrigin" => _top_origin}), do: {:error, :cross_origin}
  defp check_same_origin(_client_data), do: :ok

  defp check_backup_flags(flags) do
    backed_up = Bitwise.band(flags, @flag_backed_up) == @flag_backed_up
    backup_eligible = Bitwise.band(flags, @flag_backup_eligible) == @flag_backup_eligible

    if backed_up and not backup_eligible do
      {:error, :invalid_backup_flags}
    else
      :ok
    end
  end

  defp parse_auth_data(
         <<rp_id_hash::binary-size(32), flags::unsigned-big-8, sign_count::unsigned-big-32,
           rest::binary>>,
         rp_id
       ) do
    if :crypto.hash_equals(rp_id_hash, :crypto.hash(:sha256, rp_id)) do
      {:ok, flags, sign_count, rest}
    else
      {:error, :rp_id_mismatch}
    end
  end

  defp parse_auth_data(_authenticator_data, _rp_id), do: {:error, :malformed_authenticator_data}

  defp check_flag(flags, flag) do
    if Bitwise.band(flags, flag) == flag do
      :ok
    else
      {:error, :missing_flag}
    end
  end

  defp parse_attested_credential_data(
         <<_aaguid::binary-size(16), length::unsigned-big-16,
           credential_id::binary-size(length), rest::binary>>
       )
       when length > 0 and length <= @max_credential_id_bytes do
    case CBOR.decode(rest) do
      {:ok, cose_key, _extensions} when is_map(cose_key) -> {:ok, credential_id, cose_key}
      _other -> {:error, :invalid_cose_key}
    end
  end

  defp parse_attested_credential_data(_data), do: {:error, :malformed_attested_credential_data}

  defp validate_cose_key(%{1 => 2, 3 => @es256_alg, -1 => 1, -2 => x, -3 => y})
       when is_binary(x) and byte_size(x) == 32 and is_binary(y) and byte_size(y) == 32,
       do: :ok

  defp validate_cose_key(%{1 => 3, 3 => @rs256_alg, -1 => n, -2 => e})
       when is_binary(n) and byte_size(n) >= 256 and byte_size(n) <= 1024 and
              is_binary(e) and byte_size(e) > 0 and byte_size(e) <= 8,
       do: :ok

  defp validate_cose_key(_cose_key), do: {:error, :unsupported_key}

  defp find_credential(allow_credentials, credential_id) do
    case List.keyfind(allow_credentials, credential_id, 0) do
      {_credential_id, cose_key} -> {:ok, cose_key}
      nil -> {:error, :unknown_credential}
    end
  end

  defp verify_signature(%{1 => 2, -1 => 1, -2 => x, -3 => y}, message, signature)
       when byte_size(x) == 32 and byte_size(y) == 32 do
    key =
      {{:ECPoint, <<4>> <> x <> y},
       {:namedCurve, :pubkey_cert_records.namedCurves(:secp256r1)}}

    if :public_key.verify(message, :sha256, signature, key) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_signature(%{1 => 3, -1 => n, -2 => e}, message, signature)
       when is_binary(n) and is_binary(e) do
    key = {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}

    if :public_key.verify(message, :sha256, signature, key) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_signature(_cose_key, _message, _signature), do: {:error, :unsupported_key}
end
