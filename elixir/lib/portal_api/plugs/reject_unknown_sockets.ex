defmodule PortalAPI.Plugs.RejectUnknownSockets do
  @moduledoc """
  Rejects WebSocket upgrades for paths that this endpoint mounts no socket at.

  Phoenix dispatches sockets from the first plug of the endpoint, so an upgrade
  reaching this plug asked for a path that is not served here, typically a
  protocol version that is not deployed yet. Without this it falls through to
  the REST API redirect, which sends the client to a host that serves no
  WebSocket at all.
  """

  require Logger

  alias PortalAPI.ProblemDetails

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    if websocket_upgrade?(conn) do
      mounted = mounted_socket_paths()

      Logger.warning("Rejected WebSocket upgrade to an unmounted path",
        path: conn.request_path,
        user_agent: user_agent(conn),
        mounted_sockets: Enum.join(mounted, ", ")
      )

      ProblemDetails.send_with_code(
        conn,
        400,
        :unknown_socket,
        "No WebSocket endpoint is mounted at #{conn.request_path}. " <>
          "This portal serves: #{Enum.join(mounted, ", ")}."
      )
    else
      conn
    end
  end

  defp websocket_upgrade?(%Plug.Conn{} = conn) do
    Plug.Conn.get_req_header(conn, "upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end

  defp user_agent(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] -> user_agent
      [] -> nil
    end
  end

  defp mounted_socket_paths do
    for {path, _socket, opts} <- PortalAPI.Endpoint.__sockets__(),
        websocket = Keyword.get(opts, :websocket, true) do
      config = Phoenix.Socket.Transport.load_config(websocket, Phoenix.Transports.WebSocket)

      Path.join(path, Keyword.fetch!(config, :path))
    end
  end
end
