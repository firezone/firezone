defmodule FzCommon.FzCrypto do
  @moduledoc """
  Utilities for working with crypto functions
  """
  use Bitwise

  @wg_psk_length 32

  def psk do
    rand_base64(@wg_psk_length)
  end

  def private_key, do: private_key(:crypto.strong_rand_bytes(32))

  # Clamp random bytes for generating Curve25519 private key
  # See https://github.com/tonarino/innernet/blob/main/wireguard-control/src/key.rs#L40
  def private_key(bytes) do
    <<head>> = binary_part(bytes, 0, 1)
    <<tail>> = binary_part(bytes, 31, 1)

    clamped_head = head &&& 248
    clamped_tail = (tail &&& 127) ||| 64

    <<clamped_head>> <> binary_part(bytes, 1, 30) <> <<clamped_tail>>
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
