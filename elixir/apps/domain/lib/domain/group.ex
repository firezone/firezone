defmodule Domain.Group do
  use Ecto.Schema
  import Ecto.Changeset
  import Domain.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "groups" do
    field :name, :string
    field :type, Ecto.Enum, values: ~w[managed static]a, default: :static
    field :entity_type, Ecto.Enum, values: ~w[group org_unit]a, default: :group

    field :idp_id, :string

    field :last_synced_at, :utc_datetime_usec

    has_many :policies, Domain.Policy, foreign_key: :group_id

    has_many :memberships, Domain.Membership, foreign_key: :group_id, on_replace: :delete
    field :member_count, :integer, virtual: true
    field :count, :integer, virtual: true
    field :directory_name, :string, virtual: true
    field :directory_type, :string, virtual: true

    has_many :actors, through: [:memberships, :actor]

    belongs_to :account, Domain.Account
    belongs_to :directory, Domain.Directory

    timestamps()
  end

  def changeset(changeset) do
    import Ecto.Changeset

    changeset
    |> validate_required(~w[name type]a)
    |> trim_change(~w[name idp_id]a)
    |> validate_length(:name, min: 1, max: 255)
    |> assoc_constraint(:account)
    |> assoc_constraint(:directory)
    |> unique_constraint(:name,
      name: :groups_account_id_name_index,
      message: "A group with this name already exists."
    )
    |> check_constraint(:entity_type,
      name: :groups_entity_type_must_be_valid,
      message: "is not valid"
    )
  end
end
