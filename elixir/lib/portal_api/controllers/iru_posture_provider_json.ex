defmodule PortalAPI.IruPostureProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Iru.PostureProvider, PortalAPI.Schemas.IruPostureProvider.Schema,
    computed: [:type, :name],
    # The API token authenticates against the tenant, so it never leaves the
    # portal. error_email_count is notification bookkeeping.
    internal: [:api_token, :error_email_count]
  )

  alias Portal.Iru
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Iru.PostureProvider{} = provider) do
    PortalAPI.JSON.render(provider, PortalAPI.Schemas.IruPostureProvider.Schema, %{type: "iru", name: provider.posture_provider.name})
  end
end
