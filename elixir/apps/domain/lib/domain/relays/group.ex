defmodule Domain.Relays.Group do
  use Domain, :schema

  schema "relay_groups" do
    field :name, :string

    belongs_to :account, Domain.Accounts.Account
    has_many :relays, Domain.Relays.Relay, foreign_key: :group_id
    has_many :tokens, Domain.Relays.Token, foreign_key: :group_id

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
