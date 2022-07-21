defmodule FzHttpWeb.HeaderHelpers do
  @moduledoc """
  Helper functionalities with regards to headers
  """
  def ip_x_headers, do: ~w[x-forwarded-for]

  def trusted_proxies, do: Application.get_env(:fz_http, FzHttpWeb.Endpoint)[:trusted_proxies]
  def clients, do: Application.get_env(:fz_http, FzHttpWeb.Endpoint)[:clients]

  def proxied?, do: not is_nil(trusted_proxies())
end
