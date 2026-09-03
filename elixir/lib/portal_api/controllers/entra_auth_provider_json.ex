defmodule PortalAPI.EntraAuthProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Entra.AuthProvider, PortalAPI.Schemas.EntraAuthProvider.Schema,
    internal: [:is_verified]
  )

  alias Portal.Entra
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%Entra.AuthProvider{} = provider), do: PortalAPI.JSON.render(provider, PortalAPI.Schemas.EntraAuthProvider.Schema)
end
