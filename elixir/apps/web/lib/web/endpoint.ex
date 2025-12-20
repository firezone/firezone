defmodule Web.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :web

  # NOTE: This is only used for the LiveView session. We store per-account cookies to allow
  # multiple accounts to be logged in simultaneously. See Web.Cookie.Session.
  @session_cookie [
    store: :cookie,
    key: "_firezone_key",
    same_site: "Lax",
    max_age: 8 * 60 * 60,
    sign: true,
    secure: {__MODULE__, :cookie_secure, []},
    signing_salt: {__MODULE__, :cookie_signing_salt, []}
  ]

  if Application.compile_env(:domain, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
    plug Web.Plugs.AllowEctoSandbox
  end

  plug Plug.RewriteOn, [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]
  plug Plug.MethodOverride

  # Security Headers
  plug Web.Plugs.PutSTSHeader
  plug Web.Plugs.PutCSPHeader

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

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Session, @session_cookie

  plug Web.Plugs.FetchUserAgent
  plug Web.Router
  plug Sentry.PlugContext

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        :trace_context_headers,
        :user_agent,
        :peer_data,
        :x_headers,
        :uri,
        session: {__MODULE__, :live_view_session_options, []}
      ]
    ],
    longpoll: false

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

  def cookie_secure do
    Domain.Config.fetch_env!(:web, :cookie_secure)
  end

  def cookie_signing_salt do
    Domain.Config.fetch_env!(:web, :cookie_signing_salt)
  end

  def cookie_encryption_salt do
    Domain.Config.fetch_env!(:web, :cookie_encryption_salt)
  end

  # Configures the LiveView session cookie options.
  # IMPORTANT: Must use the same key as Plug.Session so they share session data
  def live_view_session_options do
    @session_cookie
  end
end
