defmodule Domain.Crypto do
  @wg_psk_length 32

  def psk do
    random_token(@wg_psk_length, encoder: :base64)
    |> String.slice(0, @wg_psk_length)
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
