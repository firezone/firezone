defmodule API.Endpoint do
  use Phoenix.Endpoint, otp_app: :api

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  # TODO: probably we don't need a session here at all
  plug Plug.Session, API.Session.options()

  plug API.Router
end
