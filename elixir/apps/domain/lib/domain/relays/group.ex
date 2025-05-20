defmodule Domain.Relays.Group do
  use Domain, :schema

  schema "relay_groups" do
    field :name, :string

    belongs_to :account, Domain.Accounts.Account
    has_many :relays, Domain.Relays.Relay, foreign_key: :group_id, where: [deleted_at: nil]
    has_many :tokens, Domain.Tokens.Token, foreign_key: :relay_group_id, where: [deleted_at: nil]

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    field :created_by_subject, :map
    belongs_to :created_by_identity, Domain.Auth.Identity
    belongs_to :created_by_actor, Domain.Actors.Actor

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
