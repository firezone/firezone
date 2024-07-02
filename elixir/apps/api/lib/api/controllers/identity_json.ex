defmodule API.IdentityJSON do
  alias Domain.Auth.Identity
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Identities.
  """
  def index(%{identities: identities, metadata: metadata}) do
    %{data: for(identity <- identities, do: data(identity))}
    |> Map.put(:metadata, metadata(metadata))
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
      provider_identifier: identity.provider_identifier
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
