defmodule PortalAPI.SantaPostureProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.Santa.PostureProvider,
    schema: PortalAPI.Schemas.SantaPostureProvider.Schema,
    computed: [:type, :name],
    # The API key authenticates against the tenant, so it never leaves the
    # portal. error_email_count is notification bookkeeping.
    internal: [:api_key, :error_email_count]

  alias Portal.Santa
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Santa.PostureProvider{} = provider) do
    render_fields(provider, %{type: "santa", name: provider.posture_provider.name})
  end
end
