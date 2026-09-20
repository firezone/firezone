defmodule PortalAPI.Endpoint do
  use Phoenix.Endpoint, otp_app: :portal

  # Health checks - early in pipeline for fast responses
  plug Portal.Health

  if Application.compile_env(:portal, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  plug Plug.MethodOverride
  plug :put_hsts_header
  plug Plug.Head

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Portal.Plugs.CountryCodeBlocklist

  plug Plug.RequestId
  plug PortalAPI.Plugs.PutDynamicRepo
  # TODO: Rework LoggerJSON to use Telemetry and integrate it
  # https://hexdocs.pm/phoenix/Phoenix.Logger.html
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  socket "/gateway", PortalAPI.Gateway.Socket,
    websocket: [
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(37)
    ],
    longpoll: false,
    drainer: []

  socket "/gateway/v2", PortalAPI.Gateway.V2.Socket,
    websocket: [
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(37)
    ],
    longpoll: false,
    drainer: []

  # Client sockets take `:uri` so device trust can tell a connect on the
  # mutual-TLS origin from one on the plain API origin.
  socket "/client", PortalAPI.Client.Socket,
    websocket: [
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers, :uri],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(37)
    ],
    longpoll: false,
    drainer: []

  socket "/client/v2", PortalAPI.Client.V2.Socket,
    websocket: [
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers, :uri],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(37)
    ],
    longpoll: false,
    drainer: []

  socket "/client/v3", PortalAPI.Client.V3.Socket,
    websocket: [
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers, :uri],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(37)
    ],
    longpoll: false,
    drainer: []

  socket "/relay", PortalAPI.Relay.Socket,
    websocket: [
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(41)
    ],
    longpoll: false,
    drainer: []

  plug :fetch_user_agent

  plug PortalAPI.Plugs.RescueRouterErrors

  plug Sentry.PlugContext

  def fetch_user_agent(%Plug.Conn{} = conn, _opts) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [user_agent | _] -> Plug.Conn.assign(conn, :user_agent, user_agent)
      _ -> conn
    end
  end

  def put_hsts_header(conn, _opts) do
    scheme =
      config(:url, [])
      |> Keyword.get(:scheme)

    if scheme == "https" do
      put_resp_header(
        conn,
        "strict-transport-security",
        "max-age=63072000; includeSubDomains; preload"
      )
    else
      conn
    end
  end
end
