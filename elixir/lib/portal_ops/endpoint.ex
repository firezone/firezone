defmodule PortalOps.Endpoint do
  use Phoenix.Endpoint, otp_app: :portal

  @session_cookie [
    store: :cookie,
    key: "_firezone_ops_key",
    same_site: "Lax",
    max_age: 8 * 60 * 60,
    sign: true,
    secure: {__MODULE__, :cookie_secure, []},
    signing_salt: {__MODULE__, :cookie_signing_salt, []}
  ]

  if Application.compile_env(:portal, :sql_sandbox) do
    plug Phoenix.Ecto.SQL.Sandbox
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart],
    pass: ["*/*"]

  plug Plug.Session, @session_cookie
  plug PortalOps.Router

  socket "/dashboard/live", Phoenix.LiveView.Socket,
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
    longpoll: false,
    drainer: []

  def cookie_secure do
    Portal.Config.fetch_env!(:portal, :cookie_secure)
  end

  def cookie_signing_salt do
    Portal.Config.fetch_env!(:portal, :ops_cookie_signing_salt)
  end

  def live_view_session_options do
    @session_cookie
  end
end
