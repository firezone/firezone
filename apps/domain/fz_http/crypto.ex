defmodule FzHttp.Crypto do
  @wg_psk_length 32

  def psk do
    rand_base64(@wg_psk_length)
  end

  def rand_string(length \\ 16) do
    rand_base64(length, :url)
    |> binary_part(0, length)
  end

  def rand_token(length \\ 8) do
    rand_base64(length, :url)
  end

  defp rand_base64(length, :url) do
    :crypto.strong_rand_bytes(length)
    # XXX: we want to add `padding: false` to shorten URLs
    |> Base.url_encode64()
  end

  defp rand_base64(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode64()
  end

  def hash(value), do: Argon2.hash_pwd_salt(value)

  def equal?(token, hash) when is_nil(token) or is_nil(hash), do: Argon2.no_user_verify()
  def equal?(token, hash) when token == "" or hash == "", do: Argon2.no_user_verify()
  def equal?(token, hash), do: Argon2.verify_pass(token, hash)
end
