defmodule PortalAPI.Sockets.RateLimit do
  @moduledoc """
  Rate limiting for WebSocket connections.

  Connection attempts are limited per unique combination of client IP and token.
  The refill rate and capacity are loaded at runtime from
  `PortalAPI.Sockets.RateLimit` application config, which is backed by the
  `api_socket_refill_rate` and `api_socket_capacity` config definitions.
  """

  @cost 1
  @retry_after_seconds 1

  @doc """
  Checks if a socket connection should be rate limited.

  Uses the IP address and a hash of the provided socket token as a unique key.
  If `:token` is not provided in `opts`, it falls back to hashing the
  `x-authorization` header when present, or `"none"` otherwise.

  The token bucket parameters are loaded from runtime config on each call.
  Returns `:ok` if allowed, or `{:error, :rate_limit}` if rate limited.
  """
  def check(connect_info, opts \\ []) when is_list(opts) do
    key = build_key(connect_info, opts[:token])
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    refill_rate = Keyword.fetch!(config, :refill_rate)
    capacity = Keyword.fetch!(config, :capacity)

    case PortalAPI.RateLimit.hit(key, refill_rate, capacity, @cost) do
      {:allow, _count} -> :ok
      {:deny, _refill_time} -> {:error, :rate_limit}
    end
  end

  @doc """
  Returns the number of seconds to wait before retrying.
  """
  def retry_after_seconds, do: @retry_after_seconds

  defp build_key(connect_info, token) do
    ip = extract_ip(connect_info)
    token_hash = hash_authorization(connect_info, token)
    "socket:#{ip_to_string(ip)}:#{token_hash}"
  end

  defp extract_ip(%{x_headers: x_headers, peer_data: peer_data})
       when is_list(x_headers) and x_headers != [] do
    RemoteIp.from(x_headers, PortalAPI.Endpoint.real_ip_opts()) || peer_data.address
  end

  defp extract_ip(%{peer_data: peer_data}), do: peer_data.address

  defp hash_authorization(_connect_info, token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp hash_authorization(%{x_headers: x_headers}, _token) when is_list(x_headers) do
    case List.keyfind(x_headers, "x-authorization", 0) do
      {"x-authorization", value} ->
        :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)

      _ ->
        "none"
    end
  end

  defp hash_authorization(_connect_info, _token), do: "none"

  defp ip_to_string(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp ip_to_string(ip), do: to_string(ip)
end
