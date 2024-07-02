defmodule API.IdentityProviderJSON do
  alias Domain.Auth.Provider
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Identity Providers.
  """
  def index(%{identity_providers: identity_providers, metadata: metadata}) do
    %{data: for(provider <- identity_providers, do: data(provider))}
    |> Map.put(:metadata, metadata(metadata))
  end

  @doc """
  Renders a single Identity Provider.
  """
  def show(%{identity_provider: identity_provider}) do
    %{data: data(identity_provider)}
  end

  defp data(%Provider{} = provider) do
    %{
      id: provider.id,
      name: provider.name
    }
  end

  defp metadata(%Metadata{} = metadata) do
    %{
      count: metadata.count,
      limit: metadata.limit,
      next_page: metadata.next_page_cursor,
      prev_page: metadata.previous_page_cursor
    }
  end
end
