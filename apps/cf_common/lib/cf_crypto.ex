defmodule CfCommon.CfCrypto do
  @moduledoc """
  Utilities for working with crypto functions
  """

  def rand_string(length \\ 16) do
    rand_base64(length)
    |> binary_part(0, length)
  end

  def rand_token(length \\ 8) do
    rand_base64(length)
  end

  defp rand_base64(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
  end
end
