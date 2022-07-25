defmodule FzHttpWeb.ProxyHeaders do
  @moduledoc """
  Loads proxy-related headers when it corresponds using runtime config
  """
  import FzHttpWeb.HeaderHelpers
  @behaviour Plug

  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> RemoteIp.call(remote_ip_opts())
    |> Plug.RewriteOn.call(rewrite_opts())
  end

  defp remote_ip_opts do
    RemoteIp.init(
      proxies: external_trusted_proxies(),
      clients: clients()
    )
  end

  defp rewrite_opts, do: Plug.RewriteOn.init([:x_forwarded_proto])
end
