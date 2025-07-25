defmodule Domain.Crypto do
  alias Domain.{Clients, Gateways}

  @wg_psk_length 32

  @fixed_salt <<0x46, 0x69, 0x72, 0x65, 0x7A, 0x6F, 0x6E, 0x65, 0x5F, 0x50, 0x53, 0x4B, 0x5F,
                0x53, 0x61, 0x6C, 0x74>>

  @doc """
  Generate a WireGuard PSK for a client-gateway pair.
  Returns {:ok, base64_psk} or {:error, reason}.
  """
  def psk(psk_base, %Clients.Client{} = client, %Gateways.Gateway{} = gateway) do
    with {:ok, master_secret_bytes} <- Base.decode64(psk_base),
         true <- byte_size(master_secret_bytes) == 64,
         {:ok, info_string} <- build_info_string(client, gateway) do
      psk_bytes =
        hkdf_derive_sha256(
          master_secret_bytes,
          @fixed_salt,
          info_string,
          @wg_psk_length
        )

      {:ok, Base.encode64(psk_bytes)}
    else
      _ ->
        {:error,
         "WIREGUARD_PSK_BASE not present or valid. Generate with openssl rand -base64 64."}
    end
  end

  defp build_info_string(
         %Clients.Client{id: client_id, public_key: client_pk},
         %Gateways.Gateway{id: gateway_id, public_key: gateway_pk}
       ) do
    id_byte_size = 16
    pubkey_byte_size = 32

    info_string =
      "WG_PSK" <>
        <<id_byte_size::16>> <>
        client_id <>
        <<id_byte_size::16>> <>
        gateway_id <>
        <<pubkey_byte_size::16>> <>
        client_pk <>
        <<pubkey_byte_size::16>> <> gateway_pk

    {:ok, info_string}
  end

  defp hkdf_derive_sha256(ikm, salt, info, length) do
    prk = hkdf_extract_sha256(salt, ikm)
    hkdf_expand_sha256(prk, info, length)
  end

  defp hkdf_extract_sha256(salt, ikm) do
    :crypto.mac(:hmac, :sha256, salt, ikm)
  end

  defp hkdf_expand_sha256(prk, info, length) do
    hash_len = 32
    num_blocks = div(length + hash_len - 1, hash_len)

    if num_blocks > 255 do
      raise "HKDF-Expand: Requested output length too large"
    end

    hkdf_expand_recursive(prk, info, <<>>, 1, num_blocks, <<>>)
    |> binary_part(0, length)
  end

  defp hkdf_expand_recursive(_prk, _info, _prev_t, _counter, 0, acc) do
    acc
  end

  defp hkdf_expand_recursive(prk, info, prev_t, counter, num_blocks_remaining, acc) do
    input_to_hmac = prev_t <> info <> <<counter>>
    t_n = :crypto.mac(:hmac, :sha256, prk, input_to_hmac)

    hkdf_expand_recursive(
      prk,
      info,
      t_n,
      counter + 1,
      num_blocks_remaining - 1,
      acc <> t_n
    )
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
    n =
      :math.pow(10, length)
      |> round()
      |> :rand.uniform()
      |> floor()
      |> Kernel.-(1)

    :io_lib.format("~#{length}..0B", [n])
    |> List.to_string()
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
