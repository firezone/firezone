defmodule Domain.Relays.Token do
  use Domain, :schema

  schema "relay_tokens" do
    field :value, :string, virtual: true
    field :hash, :string

    belongs_to :account, Domain.Accounts.Account
    belongs_to :group, Domain.Relays.Group

    field :created_by, Ecto.Enum, values: ~w[system identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
