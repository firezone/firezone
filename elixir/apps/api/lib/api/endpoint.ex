defmodule API.Endpoint do
  use Phoenix.Endpoint, otp_app: :api

  plug Plug.RewriteOn, [:x_forwarded_proto]
  plug Plug.MethodOverride
  plug :maybe_force_ssl
  plug Plug.Head

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug RemoteIp,
    headers: ["x-forwarded-for"],
    proxies: {__MODULE__, :external_trusted_proxies, []},
    clients: {__MODULE__, :clients, []}

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  socket "/gateway", API.Gateway.Socket, API.Sockets.options()
  socket "/device", API.Device.Socket, API.Sockets.options()
  socket "/relay", API.Relay.Socket, API.Sockets.options()

  plug :not_found

  def maybe_force_ssl(conn, _opts) do
    scheme =
      config(:url, [])
      |> Keyword.get(:scheme)

    if scheme == "https" do
      conn
    else
      opts = [rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]]
      Plug.SSL.call(conn, Plug.SSL.init(opts))
    end
  end

  def not_found(conn, _opts) do
    conn
    |> send_resp(:not_found, "Not found")
    |> halt()
  end

  def external_trusted_proxies do
    Domain.Config.fetch_env!(:api, :external_trusted_proxies)
    |> Enum.map(&to_string/1)
  end

  def clients do
    Domain.Config.fetch_env!(:api, :private_clients)
    |> Enum.map(&to_string/1)
  end
end
