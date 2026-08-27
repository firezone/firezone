defmodule PortalAPI.SantaPostureProviderJSON do
  alias Portal.Santa
  alias PortalAPI.Pagination

  @fields Santa.PostureProvider.__schema__(:fields) -- [:api_key, :error_email_count]

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Santa.PostureProvider{} = provider) do
    provider
    |> Map.take(@fields)
    |> Map.put(:type, "santa")
    |> Map.put(:name, provider.posture_provider.name)
  end
end
