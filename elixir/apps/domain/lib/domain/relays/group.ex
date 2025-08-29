defmodule Domain.Relays.Group do
  use Domain, :schema

  schema "relay_groups" do
    field :name, :string

    belongs_to :account, Domain.Accounts.Account
    # TODO: HARD-DELETE - Remove `where` after `deleted_at` is removed from the DB
    has_many :relays, Domain.Relays.Relay, foreign_key: :group_id, where: [deleted_at: nil]
    has_many :tokens, Domain.Tokens.Token, foreign_key: :relay_group_id, where: [deleted_at: nil]

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    field :created_by_subject, :map

    # TODO: HARD-DELETE - Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
