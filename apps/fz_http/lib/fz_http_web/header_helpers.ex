defmodule FzHttpWeb.HeaderHelpers do
  @moduledoc """
  Helper functionalities with regards to headers
  """
  def ip_x_headers, do: ~w[x-forwarded-for]

  def trusted_proxy, do: Application.get_env(:fz_http, FzHttpWeb.Endpoint)[:trusted_proxy]

  def proxied?, do: Application.fetch_env!(:fz_http, FzHttpWeb.Endpoint)[:proxy_forwarded]
end
