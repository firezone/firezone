defmodule Domain.Gateways.Group do
  use Domain, :schema

  schema "gateway_groups" do
    field :name_prefix, :string
    field :tags, {:array, :string}, default: []

    has_many :gateways, Domain.Gateways.Gateway, foreign_key: :group_id
    has_many :tokens, Domain.Gateways.Token, foreign_key: :group_id

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
