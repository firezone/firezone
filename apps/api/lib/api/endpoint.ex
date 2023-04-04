defmodule API.Endpoint do
  use Phoenix.Endpoint, otp_app: :api

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  socket "/gateway", API.Gateway.Socket,
    websocket: true,
    longpoll: false,
    connect_info: [:user_agent, :peer_data, :x_headers]

  socket "/client", API.Client.Socket,
    websocket: true,
    longpoll: false,
    connect_info: [:user_agent, :peer_data, :x_headers]

  socket "/relay", API.Relay.Socket,
    websocket: true,
    longpoll: false,
    connect_info: [:user_agent, :peer_data, :x_headers]
end
