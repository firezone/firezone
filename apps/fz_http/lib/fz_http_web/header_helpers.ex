defmodule FzHttpWeb.HeaderHelpers do
  @moduledoc """
  Helper functionalities with regards to headers
  """
  def ip_x_headers, do: ~w[x-forwarded-for]

  def external_trusted_proxies,
    do: Application.get_env(:fz_http, FzHttpWeb.Endpoint)[:external_trusted_proxies]

  def clients, do: Application.get_env(:fz_http, FzHttpWeb.Endpoint)[:clients]

  def proxied?, do: not is_nil(external_trusted_proxies())
end
