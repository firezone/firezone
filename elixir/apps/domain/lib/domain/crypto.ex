defmodule Domain.Crypto do
  @wg_psk_length 32

  def psk do
    random_token(@wg_psk_length, encoder: :base64)
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

  defp encode_random_token(binary, length, :user_friendly) do
    encode_random_token(binary, length, :url_encode64)
    |> String.downcase()
    |> replace_ambiguous_characters()
    |> String.slice(0, length)
  end

  defp replace_ambiguous_characters(binary, acc \\ "")

  defp replace_ambiguous_characters("", acc), do: acc

  for {mapping, replacement} <- Enum.zip(~c"-+/lO0=", ~c"ptusxyz") do
    defp replace_ambiguous_characters(<<unquote(mapping)::utf8, rest::binary>>, acc),
      do: replace_ambiguous_characters(rest, <<acc::binary, unquote(replacement)::utf8>>)
  end

  defp replace_ambiguous_characters(<<char::utf8, rest::binary>>, acc),
    do: replace_ambiguous_characters(rest, <<acc::binary, char::utf8>>)

  def hash(value), do: Argon2.hash_pwd_salt(value)

  def equal?(token, hash) when is_nil(token) or is_nil(hash), do: Argon2.no_user_verify()
  def equal?(token, hash) when token == "" or hash == "", do: Argon2.no_user_verify()
  def equal?(token, hash), do: Argon2.verify_pass(token, hash)
end
