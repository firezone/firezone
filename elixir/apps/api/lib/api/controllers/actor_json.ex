defmodule API.ActorJSON do
  alias Domain.Actors
  alias Domain.Repo.Paginator.Metadata

  @doc """
  Renders a list of Actors.
  """
  def index(%{actors: actors, metadata: metadata}) do
    %{data: for(actor <- actors, do: data(actor))}
    |> Map.put(:metadata, metadata(metadata))
  end

  @doc """
  Render a single Actor
  """
  def show(%{actor: actor}) do
    %{data: data(actor)}
  end

  defp data(%Actors.Actor{} = actor) do
    %{
      id: actor.id,
      name: actor.name,
      type: actor.type
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
