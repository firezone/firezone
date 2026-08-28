defmodule PortalAPI.IntunePostureProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.Intune.PostureProvider,
    schema: PortalAPI.Schemas.IntunePostureProvider.Schema,
    computed: [:type, :name],
    # error_email_count is notification bookkeeping, not part of the public shape.
    internal: [:error_email_count]

  alias Portal.Intune
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Intune.PostureProvider{} = provider) do
    render_fields(provider, %{type: "intune", name: provider.posture_provider.name})
  end
end
