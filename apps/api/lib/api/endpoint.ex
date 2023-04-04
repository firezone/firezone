defmodule API.Endpoint do
  use Phoenix.Endpoint, otp_app: :api

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  socket "/gateway", API.Gateway.Socket, API.Sockets.options()
  socket "/client", API.Client.Socket, API.Sockets.options()
  socket "/relay", API.Relay.Socket, API.Sockets.options()
end
