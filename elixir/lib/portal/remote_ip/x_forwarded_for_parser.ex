defmodule Portal.RemoteIp.XForwardedForParser do
  @behaviour RemoteIp.Parser

  @moduledoc """
  A custom `RemoteIp.Parser` for the `X-Forwarded-For` header that handles
  Azure Application Gateway's non-standard port appending.

  Azure App Gateway appends the source port directly to the IP address without
  RFC 7239 bracket notation, producing values like:

  - IPv4: `"107.197.104.68:53859"` instead of `"107.197.104.68"`
  - IPv6: `"2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b:64828"` instead of
    `"[2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b]:64828"`

  These fail `:inet.parse_strict_address/1`, causing `RemoteIp` to see no
  valid client IP and fall back to `peer_data.address` (the App Gateway's own
  private IP). This parser strips the trailing `:port` before delegating to
  the standard parser.
  """

  @impl RemoteIp.Parser
  def parse(header) do
    header
    |> String.trim()
    |> String.split(~r/\s*,\s*/)
    |> Enum.flat_map(&parse_ip/1)
  end

  defp parse_ip(str) do
    trimmed = String.trim(str)

    case :inet.parse_strict_address(to_charlist(trimmed)) do
      {:ok, ip} ->
        [ip]

      {:error, _} ->
        trimmed
        |> strip_port()
        |> then(fn candidate ->
          case :inet.parse_strict_address(to_charlist(candidate)) do
            {:ok, ip} -> [ip]
            {:error, _} -> []
          end
        end)
    end
  end

  # Strips the last colon-delimited segment, which is how App Gateway appends
  # the source port to both IPv4 and IPv6 addresses.
  defp strip_port(str) do
    case String.split(str, ":") do
      parts when length(parts) > 1 -> parts |> Enum.drop(-1) |> Enum.join(":")
      _ -> str
    end
  end
end
