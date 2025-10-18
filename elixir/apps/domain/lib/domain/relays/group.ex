defmodule Domain.Relays.Group do
  use Domain, :schema

  schema "relay_groups" do
    field :name, :string

    belongs_to :account, Domain.Accounts.Account
    has_many :relays, Domain.Relays.Relay, foreign_key: :group_id
    has_many :tokens, Domain.Tokens.Token, foreign_key: :relay_group_id

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    field :created_by_subject, :map

    timestamps()
  end
end
