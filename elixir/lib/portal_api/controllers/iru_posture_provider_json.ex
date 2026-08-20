defmodule PortalAPI.IruPostureProviderJSON do
  alias Portal.Iru
  alias PortalAPI.Pagination

  # The API token authenticates against the tenant, so it never leaves the
  # portal. error_email_count is notification bookkeeping.
  @fields Iru.PostureProvider.__schema__(:fields) -- [:api_token, :error_email_count]

  def index(%{providers: providers, metadata: metadata}) do
    %{data: Enum.map(providers, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{provider: provider}), do: %{data: data(provider)}

  defp data(%Iru.PostureProvider{} = provider),
    do:
      provider
      |> Map.take(@fields)
      |> Map.put(:type, "iru")
      |> Map.put(:name, provider.posture_provider.name)
end
