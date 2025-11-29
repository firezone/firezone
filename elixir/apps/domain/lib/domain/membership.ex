defmodule Domain.Membership do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          group_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  schema "actor_group_memberships" do
    belongs_to :group, Domain.Actors.Group
    belongs_to :actor, Domain.Actor

    belongs_to :account, Domain.Account

    field :last_synced_at, :utc_datetime_usec
  end

  def changeset(changeset) do
    import Ecto.Changeset
    
    changeset
    |> assoc_constraint(:actor)
    |> assoc_constraint(:group)
    |> assoc_constraint(:account)
  end
end
