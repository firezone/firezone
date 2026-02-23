defmodule Portal.RemoteIp.XForwardedForParser do
  @behaviour RemoteIp.Parser

  @moduledoc """
  A custom `RemoteIp.Parser` for the `X-Forwarded-For` header that handles
  Azure Application Gateway's non-standard port appending and RFC 7239
  bracketed IPv6 addresses.

  Azure App Gateway appends the source port directly to the IP address without
  RFC 7239 bracket notation, producing values like:

  - IPv4: `"107.197.104.68:53859"` instead of `"107.197.104.68"`
  - IPv6: `"2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b:64828"` instead of
    `"[2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b]:64828"`

  RFC-compliant proxies may send bracketed IPv6 with or without a port:

  - `"[2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b]:64828"`
  - `"[2601:5c1:8200:4e5:49f9:23d9:a1c0:bb0b]"`

  All of these fail `:inet.parse_strict_address/1`. This parser normalizes
  the address by stripping surrounding brackets and/or the trailing `:port`
  before re-attempting the parse.
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
        |> normalize_address()
        |> then(fn candidate ->
          case :inet.parse_strict_address(to_charlist(candidate)) do
            {:ok, ip} -> [ip]
            {:error, _} -> []
          end
        end)
    end
  end

  # Handles RFC 7239 bracketed IPv6 with optional port: "[ip]:port" or "[ip]".
  # Falls back to strip_port/1 for Azure's non-bracketed "ip:port" form.
  defp normalize_address(str) do
    case Regex.run(~r/^\[([^\]]+)\](?::\d+)?$/, str) do
      [_, ip] -> ip
      nil -> strip_port(str)
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
