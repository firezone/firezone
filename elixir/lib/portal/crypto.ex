defmodule Portal.Crypto do
  alias Portal.{Client, Gateway}

  @doc """
  Generates a WireGuard pre-shared key for a client-gateway pair.
  """
  def psk(
        %Client{
          id: client_id,
          public_key: client_pubkey,
          psk_base: client_psk_base
        },
        %Gateway{
          id: gateway_id,
          public_key: gateway_pubkey,
          psk_base: gateway_psk_base
        }
      )
      when not (is_nil(client_id) or is_nil(client_pubkey) or is_nil(client_psk_base) or
                  is_nil(gateway_id) or is_nil(gateway_pubkey) or is_nil(gateway_psk_base)) do
    secret_bytes = client_psk_base <> gateway_psk_base
    salt = build_salt(client_id, client_pubkey, gateway_id, gateway_pubkey)

    # PBKDF2 is overkill since inputs are high entropy, but still better than maintaining our own HKDF implementation.
    psk_bytes = :crypto.pbkdf2_hmac(:sha256, secret_bytes, salt, 1, 32)

    Base.encode64(psk_bytes)
  end

  defp build_salt(client_id, client_pubkey, gateway_id, gateway_pubkey) do
    "WG_PSK|C_ID:#{client_id}|G_ID:#{gateway_id}|C_PK:#{client_pubkey}|G_PK:#{gateway_pubkey}"
  end

  def random_token(length \\ 16, opts \\ []) do
    generator = Keyword.get(opts, :generator, :binary)
    default_encoder = if generator == :numeric, do: :raw, else: :url_encode64
    encoder = Keyword.get(opts, :encoder, default_encoder)

    generate_random_token(length, generator)
    |> encode_random_token(length, encoder)
  end

  defp generate_random_token(bytes, :binary) do
    :crypto.strong_rand_bytes(bytes)
  end

  defp generate_random_token(length, :numeric) do
    max = Integer.pow(10, length)
    n = :crypto.strong_rand_range(max)
    :io_lib.format("~#{length}..0B", [n]) |> List.to_string()
  end

  defp encode_random_token(binary, _length, :raw) do
    binary
  end

  defp encode_random_token(binary, _length, :url_encode64) do
    Base.url_encode64(binary, padding: false)
  end

  defp encode_random_token(binary, _length, :base64) do
    Base.encode64(binary)
  end

  defp encode_random_token(binary, _length, :hex32) do
    Base.hex_encode32(binary)
  end

  defp encode_random_token(binary, length, :user_friendly) do
    encode_random_token(binary, length, :url_encode64)
    |> String.downcase()
    |> replace_ambiguous_characters()
    |> String.slice(0, length)
  end

  defp replace_ambiguous_characters(binary, acc \\ "")

  defp replace_ambiguous_characters("", acc), do: acc

  for {mapping, replacement} <- Enum.zip(~c"-+/lO0=_", ~c"ptusxyzw") do
    defp replace_ambiguous_characters(<<unquote(mapping)::utf8, rest::binary>>, acc),
      do: replace_ambiguous_characters(rest, <<acc::binary, unquote(replacement)::utf8>>)
  end

  defp replace_ambiguous_characters(<<char::utf8, rest::binary>>, acc),
    do: replace_ambiguous_characters(rest, <<acc::binary, char::utf8>>)

  def hash(:argon2, value) when byte_size(value) > 0 do
    Argon2.hash_pwd_salt(value)
  end

  def hash(algo, value) when byte_size(value) > 0 do
    :crypto.hash(algo, value)
    |> Base.encode16()
    |> String.downcase()
  end

  @doc """
  Compares two secret and hash in a constant-time avoiding timing attacks.
  """
  def equal?(:argon2, secret, hash) when is_nil(secret) or is_nil(hash),
    do: Argon2.no_user_verify()

  def equal?(:argon2, secret, hash) when secret == "" or hash == "",
    do: Argon2.no_user_verify()

  def equal?(:argon2, secret, hash),
    do: Argon2.verify_pass(secret, hash)

  def equal?(algo, secret, hash) when is_nil(secret) or is_nil(hash),
    do: Plug.Crypto.secure_compare(hash(algo, "a"), "b")

  def equal?(algo, secret, hash) when secret == "" or hash == "",
    do: Plug.Crypto.secure_compare(hash(algo, "a"), "b")

  def equal?(algo, secret, hash),
    do: Plug.Crypto.secure_compare(hash(algo, secret), hash)
end
