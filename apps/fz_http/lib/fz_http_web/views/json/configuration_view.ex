defmodule FzHttpWeb.JSON.ConfigurationView do
  @moduledoc """
  Handles JSON rendering of Configuration records.
  """
  use FzHttpWeb, :view

  def render("index.json", %{configurations: configurations}) do
    %{data: render_many(configurations, __MODULE__, "configuration.json")}
  end

  def render("show.json", %{configuration: configuration}) do
    %{data: render_one(configuration, __MODULE__, "configuration.json")}
  end

  @keys_to_render ~w[
    id
    logo
    local_auth_enabled
    allow_unprivileged_device_management
    allow_unprivileged_device_configuration
    openid_connect_providers
    saml_identity_providers
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
    Map.take(configuration, @keys_to_render)
  end
end
