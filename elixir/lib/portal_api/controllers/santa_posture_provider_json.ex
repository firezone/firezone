defmodule PortalAPI.SantaPostureProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Santa.PostureProvider, PortalAPI.Schemas.SantaPostureProvider.Schema,
    computed: [:type, :name],
    # The API key authenticates against the tenant, so it never leaves the
    # portal. error_email_count is notification bookkeeping.
    internal: [:api_key, :error_email_count]
  )

  alias Portal.Santa
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Santa.PostureProvider{} = provider) do
    PortalAPI.JSON.render(provider, PortalAPI.Schemas.SantaPostureProvider.Schema, %{type: "santa", name: provider.posture_provider.name})
  end
end
