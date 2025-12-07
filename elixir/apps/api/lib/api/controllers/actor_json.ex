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
      type: actor.type,
      email: actor.email,
      allow_email_otp_sign_in: actor.allow_email_otp_sign_in,
      disabled_at: actor.disabled_at,
      last_seen_at: actor.last_seen_at,
      created_by_directory_id: actor.created_by_directory_id,
      inserted_at: actor.inserted_at,
      updated_at: actor.updated_at
    }
  end
end
