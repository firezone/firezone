defmodule API.IdentityJSON do
  alias API.Pagination
  alias Domain.Auth.Identity

  @doc """
  Renders a list of Identities.
  """
  def index(%{identities: identities, metadata: metadata}) do
    %{
      data: Enum.map(identities, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Identity
  """
  def show(%{identity: identity}) do
    %{data: data(identity)}
  end

  defp data(%Identity{} = identity) do
    %{
      id: identity.id,
      actor_id: identity.actor_id,
      provider_id: identity.provider_id,
      provider_identifier: identity.provider_identifier,
      email: identity.email
    }
  end
end
