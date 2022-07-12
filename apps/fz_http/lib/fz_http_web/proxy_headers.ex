defmodule FzHttpWeb.ProxyHeaders do
  @moduledoc """
  Loads proxy-related headers when it corresponds using runtime config
  """
  alias FzHttpWeb.HeaderHelpers
  @behaviour Plug

  def init([]) do
  end

  def call(conn, _opts) do
    if FzHttpWeb.HeaderHelpers.proxied?() do
      opts =
        RemoteIp.init(
          headers: HeaderHelpers.ip_x_headers(),
          proxy_ip: HeaderHelpers.trusted_proxy()
        )

      RemoteIp.call(conn, opts)

      opts = Plug.RewriteOn.init([:x_forwarded_proto])
      Plug.RewriteOn.call(conn, opts)
    else
      conn
    end
  end
end
