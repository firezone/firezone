defmodule FzHttpWeb.JSON.ConfigurationView do
  @moduledoc """
  Handles JSON rendering of Configuration records.
  """
  use FzHttpWeb, :view

  def render("show.json", %{configuration: configuration}) do
    %{data: render_one(configuration, __MODULE__, "configuration.json")}
  end

  @keys_to_render ~w[
    id
    local_auth_enabled
    allow_unprivileged_device_management
    allow_unprivileged_device_configuration
    disable_vpn_on_oidc_error
    vpn_session_duration
    default_client_persistent_keepalive
    default_client_mtu
    default_client_endpoint
    default_client_dns
    default_client_allowed_ips
    inserted_at
    updated_at
  ]a
  def render("configuration.json", %{configuration: configuration}) do
    Map.merge(
      Map.take(configuration, @keys_to_render),
      %{
        openid_connect_providers:
          render_many(
            configuration.openid_connect_providers,
            FzHttpWeb.JSON.OpenIDConnectProviderView,
            "openid_connect_provider.json"
          ),
        saml_identity_providers:
          render_many(
            configuration.saml_identity_providers,
            FzHttpWeb.JSON.SAMLIdentityProviderView,
            "saml_identity_provider.json"
          ),
        logo: render("logo.json", %{logo: configuration.logo})
      }
    )
  end

  def render("logo.json", %{logo: nil}) do
    %{}
  end

  def render("logo.json", %{logo: logo}) do
    Map.take(logo, ~w[url data type]a)
  end
end
