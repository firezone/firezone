defmodule FzHttpWeb.HeaderHelpers do
  @moduledoc """
  Helper functionalities with regards to headers
  """
  def ip_x_headers do
    ~w[x-forwarded-for]
  end

  def trusted_proxy do
    Application.get_env(:fz_http, FzHttpWeb.Endpoint, :trusted_proxy)
  end
end
