defmodule FzHttpWeb.RootController do
  @moduledoc """
  Firezone landing page -- show auth methods.
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    conn
    |> render(
      "auth.html",
      local_enabled: cache().get!(:local_auth_enabled),
      openid_connect_providers: cache().get!(:parsed_openid_connect_providers),
      saml_identity_providers: cache().get!(:saml_identity_providers)
    )
  end
end
