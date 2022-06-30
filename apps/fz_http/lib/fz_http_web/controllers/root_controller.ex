defmodule FzHttpWeb.RootController do
  @moduledoc """
  Firezone landing page -- show auth methods.
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    conn
    |> render(
      "auth.html",
      okta_enabled: conf(:okta_auth_enabled),
      google_enabled: conf(:google_auth_enabled),
      local_enabled: conf(:local_auth_enabled),
      openid_connect_providers: conf(:openid_connect_providers)
    )
  end

  defp conf(key) do
    Application.fetch_env!(:fz_http, key)
  end
end
