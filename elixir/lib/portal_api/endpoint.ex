defmodule PortalAPI.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :portal

  if Application.compile_env(:portal, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  plug Plug.RewriteOn, [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]
  plug Plug.MethodOverride
  plug :put_hsts_header
  plug Plug.Head

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug RemoteIp,
    headers: ["x-forwarded-for"],
    proxies: {__MODULE__, :external_trusted_proxies, []},
    clients: {__MODULE__, :clients, []}

  plug Plug.RequestId
  # TODO: Rework LoggerJSON to use Telemetry and integrate it
  # https://hexdocs.pm/phoenix/Phoenix.Logger.html
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  socket "/gateway", PortalAPI.Gateway.Socket,
    websocket: [
      transport_log: :debug,
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(37)
    ],
    longpoll: false

  socket "/client", PortalAPI.Client.Socket,
    websocket: [
      transport_log: :debug,
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(307)
    ],
    longpoll: false

  socket "/relay", PortalAPI.Relay.Socket,
    websocket: [
      transport_log: :debug,
      check_origin: :conn,
      connect_info: [:trace_context_headers, :user_agent, :peer_data, :x_headers],
      error_handler: {PortalAPI.Sockets, :handle_error, []},
      timeout: :timer.seconds(41)
    ],
    longpoll: false

  plug :fetch_user_agent
  plug PortalAPI.Router

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

  def real_ip_opts do
    [
      headers: ["x-forwarded-for"],
      proxies: {__MODULE__, :external_trusted_proxies, []},
      clients: {__MODULE__, :clients, []}
    ]
  end

  def external_trusted_proxies do
    Portal.Config.fetch_env!(:portal, :external_trusted_proxies)
    |> Enum.map(&to_string/1)
  end

  def clients do
    Portal.Config.fetch_env!(:portal, :private_clients)
    |> Enum.map(&to_string/1)
  end
end
