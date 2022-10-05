defmodule FzHttpWeb.RootController do
  @moduledoc """
  Firezone landing page -- show auth methods.
  """
  use FzHttpWeb, :controller

  alias FzHttp.Configurations, as: Conf

  def index(conn, _params) do
    conn
    |> render(
      "auth.html",
      local_enabled: Conf.get!(:local_auth_enabled),
      openid_connect_providers: Conf.get!(:parsed_openid_connect_providers)
    )
  end
end
