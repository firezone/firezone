defmodule API.ActorJSON do
  alias API.Pagination
  alias Domain.Actor

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
  Render a single Actor
  """
  def show(%{actor: actor}) do
    %{data: data(actor)}
  end

  defp data(%Actor{} = actor) do
    %{
      id: actor.id,
      name: actor.name,
      type: actor.type
    }
  end
end
