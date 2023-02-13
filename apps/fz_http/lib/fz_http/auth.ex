defmodule FzHttp.Auth do
  alias FzHttp.Config

  def fetch_oidc_provider_config(provider_id) do
    with {:ok, provider} <- fetch_provider(:openid_connect_providers, provider_id) do
      external_url = FzHttp.Config.fetch_env!(:fz_http, :external_url)

      {:ok,
       %{
         discovery_document_uri: provider.discovery_document_uri,
         client_id: provider.client_id,
         client_secret: provider.client_secret,
         redirect_uri:
           provider.redirect_uri || "#{external_url}/auth/oidc/#{provider.id}/callback/",
         response_type: provider.response_type,
         scope: provider.scope
       }}
    end
  end

  def auto_create_users?(field, provider_id) do
    fetch_provider!(field, provider_id).auto_create_users
  end

  defp fetch_provider(field, provider_id) do
    Config.fetch_config!(field)
    |> Enum.find(&(&1.id == provider_id))
    |> case do
      nil -> {:error, :not_found}
      provider -> {:ok, provider}
    end
  end

  defp fetch_provider!(field, provider_id) do
    case fetch_provider(field, provider_id) do
      {:ok, provider} ->
        provider

      {:error, :not_found} ->
        raise RuntimeError, "Unknown provider #{provider_id}"
    end
  end
end
