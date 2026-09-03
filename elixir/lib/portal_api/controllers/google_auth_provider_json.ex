defmodule PortalAPI.GoogleAuthProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Google.AuthProvider, PortalAPI.Schemas.GoogleAuthProvider.Schema,
    internal: [:is_verified]
  )

  alias Portal.Google
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%Google.AuthProvider{} = provider), do: PortalAPI.JSON.render(provider, PortalAPI.Schemas.GoogleAuthProvider.Schema)
end
