defmodule FzCommon.FzNet do
  @moduledoc """
  Network utility functions.
  """

  def ip_type(str) when is_binary(str) do
    charlist =
      str
      # remove CIDR range if exists
      |> String.split("/")
      |> List.first()
      |> String.to_charlist()

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
end
