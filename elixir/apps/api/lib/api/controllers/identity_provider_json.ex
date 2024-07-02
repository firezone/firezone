defmodule API.IdentityProviderJSON do
  alias API.Pagination
  alias Domain.Auth.Provider

  @doc """
  Renders a list of Identity Providers.
  """
  def index(%{identity_providers: identity_providers, metadata: metadata}) do
    %{
      data: Enum.map(identity_providers, &data/1),
      metadata: Pagination.metadata(metadata)
    }
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
end
