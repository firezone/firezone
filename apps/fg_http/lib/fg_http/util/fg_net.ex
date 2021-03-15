defmodule FgHttp.Util.FgNet do
  @moduledoc """
  Network utility functions.
  """

  def ip_type(str) when is_binary(str) do
    charlist = String.to_charlist(str)

    case :inet.parse_ipv4_address(charlist) do
      {:ok, _} ->
        "IPv4"

      {:error, _} ->
        case :inet.parse_ipv6_address(charlist) do
          {:ok, _} -> "IPv6"
          {:error, _} -> "unknown"
        end
    end
  end

  # Remember: a struct is a map
  def ip_type(inet) when is_map(inet) do
    inet
    |> EctoNetwork.INET.decode()
    |> ip_type()
  end
end
