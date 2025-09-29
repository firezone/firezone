defmodule Web.Endpoint do
  use Sentry.PlugCapture
  use Phoenix.Endpoint, otp_app: :web

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

  plug Web.Plugs.FetchUserAgent
  # TODO: IDP REFACTOR
  # This can be removed once all accounts are migrated
  plug Web.Session
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

        # TODO: IDP REFACTOR
        # This can be removed once all accounts are migrated since we're passing token via query param
        session: {Web.Session, :options, []}
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
end
