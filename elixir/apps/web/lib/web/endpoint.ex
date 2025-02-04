defmodule Web.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :web
  import Web.Auth

  if Application.compile_env(:domain, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
    plug Web.Sandbox
  end

  plug Plug.RewriteOn, [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]
  plug Plug.MethodOverride
  plug :put_hsts_header
  plug Web.Plugs.SecureHeaders

  plug RemoteIp,
    headers: ["x-forwarded-for"],
    proxies: {__MODULE__, :external_trusted_proxies, []},
    clients: {__MODULE__, :clients, []}

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Serve at "/" the static files from "priv/static" directory.
  plug Plug.Static,
    at: "/",
    from: :web,
    gzip: true,
    only: Web.static_paths(),
    # allows serving digested files at the root
    only_matching: ["site", "favicon"]

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket

    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :domain
  end

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        :trace_context_headers,
        :user_agent,
        :peer_data,
        :x_headers,
        :uri,
        session: {Web.Session, :options, []}
      ]
    ],
    longpoll: false

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug :fetch_user_agent

  plug Web.Session

  plug Web.Router

  plug Sentry.PlugContext

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
    Domain.Config.fetch_env!(:web, :external_trusted_proxies)
    |> Enum.map(&to_string/1)
  end

  def clients do
    Domain.Config.fetch_env!(:web, :private_clients)
    |> Enum.map(&to_string/1)
  end
end
