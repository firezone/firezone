defmodule Portal.Crypto do
  alias Portal.Device

  @user_friendly_alphabet "abcdefghijkmnopqrstuvwxyz123456789"
  @user_friendly_alphabet_size byte_size(@user_friendly_alphabet)
  @user_friendly_byte_limit div(256, @user_friendly_alphabet_size) * @user_friendly_alphabet_size

  @doc """
  Generates a WireGuard pre-shared key for an initiator and a receiver. `:site` is a receiver that
  serves the resource, and `:pool` is a receiver in a device pool. Each role has its own salt prefix
  to avoid key reuse.
  """
  def psk(
        role,
        %Device{id: initiator_id, psk_base: initiator_psk_base},
        initiator_pubkey,
        %Device{id: receiver_id, psk_base: receiver_psk_base},
        receiver_pubkey
      )
      when role in [:site, :pool] and
             not (is_nil(initiator_id) or is_nil(initiator_pubkey) or is_nil(initiator_psk_base) or
                    is_nil(receiver_id) or is_nil(receiver_pubkey) or is_nil(receiver_psk_base)) do
    salt = salt(role, initiator_id, receiver_id, initiator_pubkey, receiver_pubkey)
    derive_psk(initiator_psk_base <> receiver_psk_base, salt)
  end

  # PBKDF2 is overkill since inputs are high entropy, but still better than maintaining our own HKDF implementation.
  defp salt(:pool, initiator_id, receiver_id, initiator_pubkey, receiver_pubkey),
    do: "WG_PSK_CC|CA_ID:#{initiator_id}|CB_ID:#{receiver_id}|CA_PK:#{initiator_pubkey}|CB_PK:#{receiver_pubkey}"

  defp salt(:site, initiator_id, receiver_id, initiator_pubkey, receiver_pubkey),
    do: "WG_PSK|C_ID:#{initiator_id}|G_ID:#{receiver_id}|C_PK:#{initiator_pubkey}|G_PK:#{receiver_pubkey}"

  defp derive_psk(secret_bytes, salt) do
    :crypto.pbkdf2_hmac(:sha256, secret_bytes, salt, 1, 32)
    |> Base.encode64()
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
    encode_user_friendly(binary, length, [])
  end

  defp encode_user_friendly(_binary, 0, acc), do: IO.iodata_to_binary(acc)

  defp encode_user_friendly(<<>>, remaining, acc),
    do: encode_user_friendly(:crypto.strong_rand_bytes(remaining), remaining, acc)

  # Drop bytes past the last full multiple of the alphabet size so every symbol is equally likely.
  defp encode_user_friendly(<<byte, rest::binary>>, remaining, acc)
       when byte < @user_friendly_byte_limit do
    symbol = :binary.part(@user_friendly_alphabet, rem(byte, @user_friendly_alphabet_size), 1)
    encode_user_friendly(rest, remaining - 1, [acc, symbol])
  end

  defp encode_user_friendly(<<_byte, rest::binary>>, remaining, acc),
    do: encode_user_friendly(rest, remaining, acc)

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
