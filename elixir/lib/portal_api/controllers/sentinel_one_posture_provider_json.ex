defmodule PortalAPI.SentinelOnePostureProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.SentinelOne.PostureProvider,
    schema: PortalAPI.Schemas.SentinelOnePostureProvider.Schema,
    computed: [:type, :name],
    internal: [:api_token, :error_email_count]

  alias Portal.SentinelOne
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%SentinelOne.PostureProvider{} = provider) do
    render_fields(provider, %{type: "sentinelone", name: provider.posture_provider.name})
  end
end
