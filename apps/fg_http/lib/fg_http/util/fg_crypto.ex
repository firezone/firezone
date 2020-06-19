defmodule FgHttp.Util.FgCrypto do
  @moduledoc """
  Utilities for working with crypto functions
  """

  def rand_string(length \\ 16) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64()
    |> binary_part(0, length)
  end
end
