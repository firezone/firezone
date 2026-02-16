defmodule Portal.Policy do
  use Ecto.Schema
  import Ecto.Changeset
  alias __MODULE__.Database

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          description: String.t() | nil,
          conditions: [Portal.Policies.Condition.t()],
          group_id: Ecto.UUID.t() | nil,
          group_idp_id: String.t() | nil,
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
    field :group_idp_id, :string
    belongs_to :resource, Portal.Resource

    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_length(:description, min: 1, max: 255)
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

  @spec reconnect_orphaned_policies(Ecto.UUID.t()) :: non_neg_integer()
  def reconnect_orphaned_policies(account_id) do
    Database.reconnect_orphaned_policies(account_id)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Group
    alias Portal.Policy
    alias Portal.Safe

    @spec reconnect_orphaned_policies(Ecto.UUID.t()) :: non_neg_integer()
    def reconnect_orphaned_policies(account_id) do
      now = DateTime.utc_now()

      {count, _} =
        from(p in Policy,
          join: g in Group,
          on: g.account_id == p.account_id and g.idp_id == p.group_idp_id,
          where: p.account_id == ^account_id,
          where: is_nil(p.group_id),
          where: not is_nil(p.group_idp_id),
          update: [set: [group_id: g.id, updated_at: ^now]]
        )
        |> Safe.unscoped()
        |> Safe.update_all([])

      count
    end
  end
end
