defmodule Portal.Endpoint do
  @moduledoc """
  Public HTTP and HTTPS ingress for the web and API endpoints.
  """

  use Phoenix.Endpoint, otp_app: :portal

  plug Portal.Health
  plug :drop_forwarded_headers
  plug Plug.SSL
  plug :dispatch

  def drop_forwarded_headers(%Plug.Conn{} = conn, _opts) do
    Enum.reduce(
      ~w(x-forwarded-for x-forwarded-host x-forwarded-port x-forwarded-proto),
      conn,
      &Plug.Conn.delete_req_header(&2, &1)
    )
  end

  def dispatch(%Plug.Conn{} = conn, _opts) do
    host = String.downcase(conn.host)
    web_host = configured_host(:web_external_url)
    mtls_host = configured_host(:mtls_external_url)

    cond do
      host == web_host ->
        forward(conn, PortalWeb.Endpoint)

      host == mtls_host and not websocket_upgrade?(conn) ->
        conn
        |> Plug.Conn.send_resp(:not_found, "Not Found")
        |> Plug.Conn.halt()

      host in api_hosts() ->
        forward(conn, PortalAPI.Endpoint)

      true ->
        conn
        |> Plug.Conn.send_resp(:not_found, "Not Found")
        |> Plug.Conn.halt()
    end
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
    [:api_external_url, :rest_api_url, :flow_logs_api_url, :mtls_external_url]
    |> Enum.map(&configured_host/1)
    |> Enum.reject(&is_nil/1)
  end

  defp configured_host(key) do
    with url when is_binary(url) <- Portal.Config.get_env(:portal, key),
         %URI{host: host} when is_binary(host) <- URI.parse(url) do
      String.downcase(host)
    else
      _unconfigured -> nil
    end
  end
end
