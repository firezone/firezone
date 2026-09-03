defmodule PortalAPI.OktaAuthProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Okta.AuthProvider, PortalAPI.Schemas.OktaAuthProvider.Schema,
    internal: [:client_secret, :discovery_document_uri, :is_verified]
  )

  alias Portal.Okta
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%Okta.AuthProvider{} = provider), do: PortalAPI.JSON.render(provider, PortalAPI.Schemas.OktaAuthProvider.Schema)
end
