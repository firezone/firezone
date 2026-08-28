defmodule PortalAPI.OktaAuthProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.Okta.AuthProvider,
    schema: PortalAPI.Schemas.OktaAuthProvider.Schema,
    internal: [:client_secret, :discovery_document_uri, :is_verified]

  alias Portal.Okta
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%Okta.AuthProvider{} = provider), do: render_fields(provider)
end
