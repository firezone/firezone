defmodule PortalAPI.MembershipJSON do
  use PortalAPI.JSON,
    struct: Portal.Actor,
    schema: PortalAPI.Schemas.Membership.Schema,
    internal: [
      :account_id,
      :allow_email_otp_sign_in,
      :created_by_directory_id,
      :email,
      :identity_count,
      :inserted_at,
      :is_disabled,
      :last_seen_at,
      :password_hash,
      :preferences,
      :updated_at
    ]

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

  defp data(%Actor{} = actor), do: render_fields(actor)
end
