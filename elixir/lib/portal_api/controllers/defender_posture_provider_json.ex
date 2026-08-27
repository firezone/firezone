defmodule PortalAPI.DefenderPostureProviderJSON do
  alias Portal.Defender
  alias PortalAPI.Pagination

  # error_email_count is notification bookkeeping, not part of the public shape.
  @fields Defender.PostureProvider.__schema__(:fields) -- [:error_email_count]

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Defender.PostureProvider{} = provider),
    do:
      provider
      |> Map.take(@fields)
      |> Map.put(:type, "defender")
      |> Map.put(:name, provider.posture_provider.name)
end
