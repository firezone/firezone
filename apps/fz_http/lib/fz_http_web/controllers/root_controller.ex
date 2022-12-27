defmodule FzHttpWeb.RootController do
  @moduledoc """
  Firezone landing page -- show auth methods.
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    conn
    |> render(
      "auth.html",
      local_enabled: FzHttp.Configurations.get!(:local_auth_enabled),
      openid_connect_providers: FzHttp.Configurations.get!(:openid_connect_providers),
      saml_identity_providers: FzHttp.Configurations.get!(:saml_identity_providers)
    )
  end
end
