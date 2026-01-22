defmodule Portal.Policy do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          description: String.t() | nil,
          conditions: [Portal.Policies.Condition.t()],
          group_id: Ecto.UUID.t(),
          resource_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "policies" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :description, :string

    embeds_many :conditions, Portal.Policies.Condition, on_replace: :delete

    belongs_to :group, Portal.Group, foreign_key: :group_id
    belongs_to :resource, Portal.Resource

    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_length(:description, min: 1, max: 1024)
    |> unique_constraint(
      :base,
      name: :policies_account_id_resource_id_group_id_index,
      message: "Policy for the selected Group and Resource already exists"
    )
    |> assoc_constraint(:account)
    |> assoc_constraint(:resource)
    |> assoc_constraint(:group)
    |> unique_constraint(
      :base,
      name: :policies_group_id_fkey,
      message: "Not allowed to create policies for groups outside of your account"
    )
    |> unique_constraint(
      :base,
      name: :policies_resource_id_fkey,
      message: "Not allowed to create policies for resources outside of your account"
    )
  end
end
