defmodule Domain.Site do
  use Domain, :schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          managed_by: :account | :system,
          account_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "sites" do
    field :name, :string

    field :managed_by, Ecto.Enum, values: ~w[account system]a, defauilt: :account

    belongs_to :account, Domain.Account
    has_many :gateways, Domain.Gateway
    has_many :tokens, Domain.Token
    has_many :resources, Domain.Resource

    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required(:name)
    |> validate_length(:name, min: 1, max: 64)
    |> unique_constraint(:name, name: :sites_account_id_name_managed_by_index)
  end
end
