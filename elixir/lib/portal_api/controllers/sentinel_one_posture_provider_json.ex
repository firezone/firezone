defmodule PortalAPI.SentinelOnePostureProviderJSON do
  alias Portal.SentinelOne
  alias PortalAPI.Pagination

  @fields SentinelOne.PostureProvider.__schema__(:fields) -- [:api_token, :error_email_count]

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%SentinelOne.PostureProvider{} = provider),
    do:
      provider
      |> Map.take(@fields)
      |> Map.put(:type, "sentinelone")
      |> Map.put(:name, provider.posture_provider.name)
end
