defmodule FzHttpWeb.RootController do
  @moduledoc """
  Firezone landing page -- show auth methods.
  """
  use FzHttpWeb, :controller

  def index(conn, _params) do
    %{
      local_auth_enabled: {_, local_auth_enabled},
      openid_connect_providers: {_, openid_connect_providers},
      saml_identity_providers: {_, saml_identity_providers}
    } =
      FzHttp.Config.fetch_source_and_configs!([
        :local_auth_enabled,
        :openid_connect_providers,
        :saml_identity_providers
      ])

    conn
    |> render(
      "auth.html",
      local_enabled: local_auth_enabled,
      openid_connect_providers: openid_connect_providers,
      saml_identity_providers: saml_identity_providers
    )
  end
end
