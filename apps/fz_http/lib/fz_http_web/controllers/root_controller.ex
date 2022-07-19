defmodule FzHttpWeb.RootController do
  @moduledoc """
  Firezone landing page -- show auth methods.
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    conn
    |> render(
      "auth.html",
      local_enabled: FzHttp.Conf.get(:local_auth_enabled),
      openid_connect_providers: FzHttp.Conf.get(:openid_connect_providers)
    )
  end
end
