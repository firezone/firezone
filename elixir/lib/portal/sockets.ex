defmodule Portal.Sockets do
  @moduledoc """
    Keeps our socket ID format in one place.
  """

  @typedoc ~s|A socket identifier in the format "socket:<uuid>"|
  @type socket_id :: String.t()

  @spec socket_id(Ecto.UUID.t()) :: socket_id()
  def socket_id(id) when is_binary(id), do: "socket:#{id}"

  @doc """
  Resolves the client address of a WebSocket from its connect info.

  Sockets get their headers before `Portal.Endpoint` can rewrite the connection,
  so the forwarded address is resolved here, with the peer address as fallback,
  and IPv4-mapped IPv6 addresses are normalized to IPv4.
  """
  @spec remote_ip(map()) :: :inet.ip_address()
  def remote_ip(connect_info) do
    x_headers = Map.get(connect_info, :x_headers)

    forwarded_ip =
      if is_list(x_headers) and x_headers != [] do
        RemoteIp.from(x_headers, Portal.Endpoint.real_ip_opts())
      end

    Portal.Types.IP.unmap(forwarded_ip || connect_info.peer_data.address)
  end
end
