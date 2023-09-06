defmodule Domain.Crypto do
  @wg_psk_length 32

  def psk do
    rand_base64(@wg_psk_length)
  end

  def rand_number(length \\ 8) when length > 0 do
    n =
      :math.pow(10, length)
      |> round()
      |> :rand.uniform()
      |> floor()
      |> Kernel.-(1)

    :io_lib.format("~#{length}..0B", [n])
    |> List.to_string()
  end

  def rand_string(length \\ 16) when length > 0 do
    rand_base64(length, :url)
    |> binary_part(0, length)
  end

  def rand_token(length \\ 8) when length > 0 do
    rand_base64(length, :url)
  end

  defp rand_base64(length, :url) when length > 0 do
    :crypto.strong_rand_bytes(length)
    # XXX: we want to add `padding: false` to shorten URLs
    |> Base.url_encode64(padding: false)
  end

  defp rand_base64(length) when length > 0 do
    :crypto.strong_rand_bytes(length)
    |> Base.encode64()
  end

  def hash(value), do: Argon2.hash_pwd_salt(value)

  def equal?(token, hash) when is_nil(token) or is_nil(hash), do: Argon2.no_user_verify()
  def equal?(token, hash) when token == "" or hash == "", do: Argon2.no_user_verify()
  def equal?(token, hash), do: Argon2.verify_pass(token, hash)
end
