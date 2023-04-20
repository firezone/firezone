defmodule API.Endpoint do
  use Phoenix.Endpoint, otp_app: :api

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RewriteOn, [:x_forwarded_proto]
  plug Plug.MethodOverride

  plug RemoteIp,
    headers: ["x-forwarded-for"],
    proxies: {__MODULE__, :external_trusted_proxies, []},
    clients: {__MODULE__, :clients, []}

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  socket "/gateway", API.Gateway.Socket, API.Sockets.options()
  socket "/client", API.Client.Socket, API.Sockets.options()
  socket "/relay", API.Relay.Socket, API.Sockets.options()

  def external_trusted_proxies do
    Domain.Config.fetch_env!(:api, :external_trusted_proxies)
    |> Enum.map(&to_string/1)
  end

  def clients do
    Domain.Config.fetch_env!(:api, :private_clients)
    |> Enum.map(&to_string/1)
  end
end
