defmodule FzHttpWeb.HeaderHelpers do
  @moduledoc """
  Helper functionalities with regards to headers
  """

  @remote_ip_headers ["x-forwarded-for"]

  def external_trusted_proxies, do: conf(:external_trusted_proxies)

  def clients, do: conf(:private_clients)

  def proxied?, do: not (external_trusted_proxies() == false)

  def remote_ip_opts do
    [
      headers: @remote_ip_headers,
      proxies: external_trusted_proxies(),
      clients: clients()
    ]
  end

  defp conf(key) when is_atom(key) do
    Application.fetch_env!(:fz_http, key)
  end
end
