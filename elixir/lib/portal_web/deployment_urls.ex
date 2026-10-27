defmodule PortalWeb.DeploymentURLs do
  @moduledoc """
  The URLs Clients and Gateways must be pointed at to reach this deployment.

  They ship with Firezone's hosted URLs as defaults, so each function returns nil
  when this deployment uses that default and there is nothing to configure.
  """

  @doc """
  The URL Clients and Gateways connect to, or nil when it's the default. They
  accept the portal's https URL and switch to WebSockets themselves.
  """
  @spec api_url() :: String.t() | nil
  def api_url do
    Portal.Config.get_env(:portal, :api_url_override) ||
      unless_default(Portal.Config.get_env(:portal, :api_external_url), "api.firezone.dev")
  end

  @doc "The URL Clients sign in at, or nil when it's the default."
  @spec auth_url() :: String.t() | nil
  def auth_url do
    unless_default(Portal.Config.get_env(:portal, :web_external_url), "app.firezone.dev")
  end

  defp unless_default(url, default_host) do
    if url && URI.parse(url).host != default_host, do: url
  end
end
