defmodule Domain.Relays.Token do
  use Domain, :schema

  schema "relay_tokens" do
    field :value, :string, virtual: true
    field :hash, :string

    belongs_to :group, Domain.Relays.Group

    field :deleted_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
