defmodule Domain.Policy do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          description: String.t() | nil,
          conditions: [Domain.Policies.Condition.t()],
          actor_group_id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "policies" do
    field :description, :string

    embeds_many :conditions, Domain.Policies.Condition, on_replace: :delete

    belongs_to :actor_group, Domain.ActorGroup
    belongs_to :resource, Domain.Resource
    belongs_to :account, Domain.Account

    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_length(:description, min: 1, max: 1024)
    |> unique_constraint(
      :base,
      name: :policies_account_id_resource_id_actor_group_id_index,
      message: "Policy for the selected Group and Resource already exists"
    )
    |> assoc_constraint(:resource)
    |> assoc_constraint(:actor_group)
    |> unique_constraint(
      :base,
      name: :policies_actor_group_id_fkey,
      message: "Not allowed to create policies for groups outside of your account"
    )
    |> unique_constraint(
      :base,
      name: :policies_resource_id_fkey,
      message: "Not allowed to create policies for resources outside of your account"
    )
  end
end
