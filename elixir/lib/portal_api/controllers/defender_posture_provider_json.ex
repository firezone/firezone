defmodule PortalAPI.DefenderPostureProviderJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Defender.PostureProvider, PortalAPI.Schemas.DefenderPostureProvider.Schema,
    computed: [:type, :name],
    # error_email_count is notification bookkeeping, not part of the public shape.
    internal: [:error_email_count]
  )

  alias Portal.Defender
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Defender.PostureProvider{} = provider) do
    PortalAPI.JSON.render(provider, PortalAPI.Schemas.DefenderPostureProvider.Schema, %{type: "defender", name: provider.posture_provider.name})
  end
end
