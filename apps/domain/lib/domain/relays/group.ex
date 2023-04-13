defmodule Domain.Relays.Group do
  use Domain, :schema

  schema "relay_groups" do
    field :name, :string

    has_many :relays, Domain.Relays.Relay, foreign_key: :group_id
    has_many :tokens, Domain.Relays.Token, foreign_key: :group_id

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
