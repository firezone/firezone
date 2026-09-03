defmodule PortalAPI.ActorJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Actor, PortalAPI.Schemas.Actor.Schema,
    internal: [:account_id, :identity_count, :password_hash, :preferences]
  )

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
  Render a single Actor
  """
  def show(%{actor: actor}) do
    %{data: data(actor)}
  end

  defp data(%Actor{} = actor), do: PortalAPI.JSON.render(actor, PortalAPI.Schemas.Actor.Schema)
end
