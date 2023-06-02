defmodule Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :web

  plug Plug.RewriteOn, [:x_forwarded_proto]
  plug Plug.MethodOverride
  plug :maybe_force_ssl
  plug Plug.Head

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [
        :user_agent,
        :peer_data,
        :x_headers,
        :uri,
        session: {Web.Session, :options, []}
      ]
    ],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :web,
    gzip: false,
    only: Web.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket

    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :domain
  end

  plug RemoteIp,
    headers: ["x-forwarded-for"],
    proxies: {__MODULE__, :external_trusted_proxies, []},
    clients: {__MODULE__, :clients, []}

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  # We wrap Plug.Session because it's options are resolved at compile-time,
  # which doesn't work with Elixir releases and runtime configuration
  plug :session

  plug Web.Router

  def maybe_force_ssl(conn, _opts) do
    scheme =
      config(:url, [])
      |> Keyword.get(:scheme)

    if scheme == "https" do
      opts = [rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]]
      Plug.SSL.call(conn, Plug.SSL.init(opts))
    else
      conn
    end
  end

  def session(conn, _opts) do
    opts = Web.Session.options()
    Plug.Session.call(conn, Plug.Session.init(opts))
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
