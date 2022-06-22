defmodule FzCommon.FzCrypto do
  @moduledoc """
  Utilities for working with crypto functions
  """
  use Bitwise

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
    |> Base.url_encode64()
  end

  defp rand_base64(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode64()
  end
end
