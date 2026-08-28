defmodule PortalAPI.IruPostureProviderJSON do
  use PortalAPI.JSON,
    struct: Portal.Iru.PostureProvider,
    schema: PortalAPI.Schemas.IruPostureProvider.Schema,
    computed: [:type, :name],
    # The API token authenticates against the tenant, so it never leaves the
    # portal. error_email_count is notification bookkeeping.
    internal: [:api_token, :error_email_count]

  alias Portal.Iru
  alias PortalAPI.Pagination

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Iru.PostureProvider{} = provider) do
    render_fields(provider, %{type: "iru", name: provider.posture_provider.name})
  end
end
