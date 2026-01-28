defmodule Portal.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          group_id: Ecto.UUID.t(),
          actor_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  schema "memberships" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :group, Portal.Group
    belongs_to :actor, Portal.Actor

    field :last_synced_at, :utc_datetime_usec
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:actor)
    |> assoc_constraint(:group)
    |> assoc_constraint(:account)
  end
end
