defmodule PortalAPI.MembershipJSON do
  alias PortalAPI.Pagination
  alias Portal.Actor

  @doc """
  Renders a list of Actors.
  """
  def index(%{actors: actors, metadata: metadata}) do
    %{
      data: Enum.map(actors, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Renders a list of Actor IDs for an Actor Group
  """
  def memberships(%{actor_ids: actor_ids}) do
    %{data: %{actor_ids: actor_ids}}
  end

  defp data(%Actor{} = actor) do
    %{
      id: actor.id,
      name: actor.name,
      type: actor.type
    }
  end
end
