defmodule FzHttpWeb.API.ConfigurationView do
  use FzHttpWeb, :view
  alias FzHttpWeb.API.ConfigurationView

  def render("index.json", %{configurations: configurations}) do
    %{data: render_many(configurations, ConfigurationView, "configuration.json")}
  end

  def render("show.json", %{configuration: configuration}) do
    %{data: render_one(configuration, ConfigurationView, "configuration.json")}
  end

  def render("configuration.json", %{configuration: configuration}) do
    %{
      id: configuration.id,
      logo: configuration.logo,
      local_auth_enabled: configuration.local_auth_enabled,
      allow_unprivileged_device_management: configuration.allow_unprivileged_device_management,
      allow_unprivileged_device_configuration:
        configuration.allow_unprivileged_device_configuration,
      openid_connect_providers: configuration.openid_connect_providers,
      # Add :saml_identity_providers when merged
      disable_vpn_on_oidc_error: configuration.disable_vpn_on_oidc_error,
      auto_create_oidc_users: configuration.auto_create_oidc_users
    }
  end
end
