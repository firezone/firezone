defmodule Domain.Gateways.Group do
  use Domain, :schema

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          name: String.t(),
          managed_by: :account | :system,
          account_id: Ecto.UUID.t(),
          created_by: :actor | :identity | :system,
          created_by_subject: map(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "gateway_groups" do
    field :name, :string

    field :managed_by, Ecto.Enum, values: ~w[account system]a

    belongs_to :account, Domain.Accounts.Account
    has_many :gateways, Domain.Gateways.Gateway, foreign_key: :group_id

    has_many :tokens, Domain.Tokens.Token, foreign_key: :gateway_group_id

    has_many :connections, Domain.Resources.Connection, foreign_key: :gateway_group_id

    field :created_by, Ecto.Enum, values: ~w[actor identity system]a
    field :created_by_subject, :map

    timestamps()
  end
end
