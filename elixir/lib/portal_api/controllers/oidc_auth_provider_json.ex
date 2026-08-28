defmodule PortalAPI.OIDCAuthProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.OIDC.AuthProvider,
    schema: PortalAPI.Schemas.OIDCAuthProvider.Schema,
    internal: [:client_secret, :is_legacy, :is_verified]

  alias Portal.OIDC
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}) do
    %{data: data(provider)}
  end

  defp data(%OIDC.AuthProvider{} = provider), do: render_fields(provider)
end
