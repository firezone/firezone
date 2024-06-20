defmodule API.ActorGroupJSON do
  alias Domain.Actors
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Actor Groups.
  """
  def index(%{actor_groups: actor_groups, metadata: metadata}) do
    %{data: for(actor_group <- actor_groups, do: data(actor_group))}
    |> Map.put(:metadata, metadata(metadata))
  end

  @doc """
  Render a single Actor Group
  """
  def show(%{actor_group: actor_group}) do
    %{data: data(actor_group)}
  end

  defp data(%Actors.Group{} = actor_group) do
    %{
      id: actor_group.id,
      name: actor_group.name
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
