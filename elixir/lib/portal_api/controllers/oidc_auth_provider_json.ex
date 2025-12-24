defmodule API.OIDCAuthProviderJSON do
  alias Domain.OIDC

  def index(%{providers: providers}) do
    %{data: Enum.map(providers, &data/1)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%OIDC.AuthProvider{} = provider) do
    %{
      id: provider.id,
      account_id: provider.account_id,
      name: provider.name,
      issuer: provider.issuer,
      context: provider.context,
      client_session_lifetime_secs: provider.client_session_lifetime_secs,
      portal_session_lifetime_secs: provider.portal_session_lifetime_secs,
      is_disabled: provider.is_disabled,
      is_default: provider.is_default,
      client_id: provider.client_id,
      discovery_document_uri: provider.discovery_document_uri,
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }
  end
end
