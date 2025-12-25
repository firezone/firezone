defmodule Portal.Site do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          managed_by: :account | :system,
          account_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "sites" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :name, :string

    field :managed_by, Ecto.Enum, values: ~w[account system]a, default: :account

    has_many :gateways, Portal.Gateway, references: :id
    has_many :gateway_tokens, Portal.GatewayToken, references: :id
    has_many :resources, Portal.Resource, references: :id

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(:name)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :sites_account_id_name_managed_by_index)
  end
end
