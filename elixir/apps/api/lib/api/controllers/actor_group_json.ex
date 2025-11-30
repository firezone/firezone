defmodule API.ActorGroupJSON do
  alias API.Pagination
  alias Domain.ActorGroup

  @doc """
  Renders a list of Actor Groups.
  """
  def index(%{actor_groups: actor_groups, metadata: metadata}) do
    %{
      data: Enum.map(actor_groups, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Actor Group
  """
  def show(%{actor_group: actor_group}) do
    %{data: data(actor_group)}
  end

  defp data(%ActorGroup{} = actor_group) do
    %{
      id: actor_group.id,
      name: actor_group.name
    }
  end
end
