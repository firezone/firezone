defmodule Portal.Endpoint do
  @moduledoc """
  Public HTTP and HTTPS ingress for the web and API endpoints.
  """

  use Phoenix.Endpoint, otp_app: :portal

  @forwarded_headers ~w(x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto)
  @geo_headers ~w(x-azure-geo-country x-geo-location-region x-geo-location-city)
  @proxy_headers @forwarded_headers ++ @geo_headers
  @rewrite_on Plug.RewriteOn.init([:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto])
  @real_ip_opts [
    headers: ["x-forwarded-for"],
    parsers: %{"x-forwarded-for" => Portal.RemoteIp.XForwardedForParser},
    proxies: {__MODULE__, :external_trusted_proxies, []},
    clients: {__MODULE__, :clients, []}
  ]
  @remote_ip RemoteIp.init(@real_ip_opts)
  @ssl_opts Plug.SSL.init([])

  plug Portal.Health
  plug :apply_forwarded_headers
  plug :redirect_to_https
  plug :dispatch

  # Clients reach this listener directly, so the headers they send are only
  # trustworthy when the request itself comes from a declared reverse proxy.
  # The geo headers decide the location that policy conditions match on, so
  # they are dropped with the rest. Everything behind this endpoint reads the
  # connection and does not look at these headers again.
  def apply_forwarded_headers(%Plug.Conn{} = conn, _opts) do
    conn = %{conn | remote_ip: Portal.Types.IP.unmap(conn.remote_ip)}

    if from_trusted_proxy?(conn) do
      conn
      |> Plug.RewriteOn.call(@rewrite_on)
      |> RemoteIp.call(@remote_ip)
      |> then(&%{&1 | remote_ip: Portal.Types.IP.unmap(&1.remote_ip)})
    else
      Enum.reduce(@proxy_headers, conn, &Plug.Conn.delete_req_header(&2, &1))
    end
  end

  # Without a TLS listener something in front terminates TLS, and redirecting
  # would send the request back to it in a loop.
  def redirect_to_https(%Plug.Conn{} = conn, _opts) do
    if terminates_tls?() do
      Plug.SSL.call(conn, @ssl_opts)
    else
      conn
    end
  end

  def dispatch(%Plug.Conn{} = conn, _opts) do
    host = String.downcase(conn.host)
    origin = {host, conn.port}
    web_host = configured_host(:web_external_url)
    mtls_origin = configured_origin(:mtls_external_url)

    cond do
      origin == mtls_origin and not websocket_upgrade?(conn) ->
        conn
        |> Plug.Conn.send_resp(:not_found, "Not Found")
        |> Plug.Conn.halt()

      origin == mtls_origin ->
        forward(conn, PortalAPI.Endpoint)

      host == web_host ->
        forward(conn, PortalWeb.Endpoint)

      host in api_hosts() ->
        forward(conn, PortalAPI.Endpoint)

      true ->
        conn
        |> Plug.Conn.send_resp(:not_found, "Not Found")
        |> Plug.Conn.halt()
    end
  end

  @doc """
  Options for resolving the client IP address from WebSocket connect headers.

  Sockets get their headers before this endpoint can rewrite the connection, so
  they resolve the address themselves and fall back to the peer address.
  """
  def real_ip_opts do
    @real_ip_opts
  end

  def external_trusted_proxies do
    Portal.Config.fetch_env!(:portal, :external_trusted_proxies)
    |> Enum.map(&to_string/1)
  end

  def clients do
    Portal.Config.fetch_env!(:portal, :private_clients)
    |> Enum.map(&to_string/1)
  end

  defp forward(conn, endpoint) do
    conn
    |> endpoint.call(endpoint.init([]))
    |> Plug.Conn.halt()
  end

  defp websocket_upgrade?(conn) do
    Plug.Conn.get_req_header(conn, "upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp api_hosts do
    [:api_external_url, :rest_api_url, :flow_logs_api_url]
    |> Enum.map(&configured_host/1)
    |> Enum.reject(&is_nil/1)
  end

  defp configured_host(key) do
    case configured_origin(key) do
      {host, _port} -> host
      nil -> nil
    end
  end

  defp configured_origin(key) do
    with url when is_binary(url) <- Portal.Config.get_env(:portal, key),
         %URI{host: host, port: port} when is_binary(host) and is_integer(port) <- URI.parse(url) do
      {String.downcase(host), port}
    else
      _unconfigured -> nil
    end
  end

  defp from_trusted_proxy?(%Plug.Conn{remote_ip: peer}) do
    peer = %Postgrex.INET{address: peer}

    Portal.Config.fetch_env!(:portal, :external_trusted_proxies)
    |> Enum.any?(&Portal.Types.CIDR.contains?(as_block(&1), peer))
  end

  # A bare address carries no netmask, and CIDR.range/1 would then read an IPv6
  # address as a /32 block.
  defp as_block(%Postgrex.INET{netmask: nil} = inet) do
    %{inet | netmask: Portal.Types.CIDR.max_netmask(inet)}
  end

  defp as_block(%Postgrex.INET{} = inet) do
    inet
  end

  defp terminates_tls? do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.has_key?(:https)
  end
end
