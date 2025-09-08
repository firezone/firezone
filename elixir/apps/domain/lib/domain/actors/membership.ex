defmodule Domain.Actors.Membership do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          group_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  schema "actor_group_memberships" do
    belongs_to :group, Domain.Actors.Group
    belongs_to :actor, Domain.Actors.Actor

    belongs_to :account, Domain.Accounts.Account

    field :synced_at, :utc_datetime_usec
  end
end
