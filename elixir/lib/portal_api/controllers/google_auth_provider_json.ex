defmodule PortalAPI.GoogleAuthProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.Google.AuthProvider,
    schema: PortalAPI.Schemas.GoogleAuthProvider.Schema,
    internal: [:is_verified]

  alias Portal.Google
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%Google.AuthProvider{} = provider), do: render_fields(provider)
end
