defmodule PortalWeb.DeploymentURLs do
  @moduledoc """
  The URLs Clients and Gateways must be pointed at to reach this deployment.

  They ship with Firezone's hosted URLs as defaults, so each function returns nil
  when this deployment uses that default and there is nothing to configure.
  """

  @default_api_url "wss://api.firezone.dev/"
  @default_auth_url "https://app.firezone.dev/"

  @doc "The WebSocket URL Clients and Gateways connect to, or nil when it's the default."
  @spec api_url() :: String.t() | nil
  def api_url do
    case Portal.Config.get_env(:portal, :api_url_override) do
      nil ->
        :portal
        |> Portal.Config.get_env(:api_external_url)
        |> normalize(%{"https" => "wss", "http" => "ws"})
        |> unless_default(@default_api_url)

      url ->
        url
    end
  end

  @doc "The URL Clients sign in at, or nil when it's the default."
  @spec auth_url() :: String.t() | nil
  def auth_url do
    :portal
    |> Portal.Config.get_env(:web_external_url)
    |> normalize(%{})
    |> unless_default(@default_auth_url)
  end

  defp normalize(nil, _schemes), do: nil

  defp normalize(url, schemes) do
    uri = URI.parse(url)
    URI.to_string(%{uri | scheme: Map.get(schemes, uri.scheme, uri.scheme), path: uri.path || "/"})
  end

  defp unless_default(url, url), do: nil
  defp unless_default(url, _default), do: url
end
