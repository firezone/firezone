defmodule FzCommon.FzCrypto do
  @moduledoc """
  Utilities for working with crypto functions
  """

  @wg_psk_length 32

  def gen_secrets do
    [
      {"DEFAULT_ADMIN_PASSWORD", rand_base64(12)},
      {"GUARDIAN_SECRET_KEY", rand_base64(48)},
      {"SECRET_KEY_BASE", rand_base64(48)},
      {"LIVE_VIEW_SIGNING_SALT", rand_base64(24)},
      {"COOKIE_SIGNING_SALT", rand_base64(6)},
      {"COOKIE_ENCRYPTION_SALT", rand_base64(6)},
      {"DATABASE_ENCRYPTION_KEY", rand_base64(32)}
    ]
    |> Enum.map(fn {k, v} -> "#{k}=#{v}")
    |> Enum.join("\n")
    |> IO.puts()
  end

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
    |> Base.url_encode64()
  end

  defp rand_base64(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode64()
  end
end
