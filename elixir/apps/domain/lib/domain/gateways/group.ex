defmodule Domain.Gateways.Group do
  use Domain, :schema

  schema "gateway_groups" do
    field :name_prefix, :string
    field :tags, {:array, :string}, default: []

    belongs_to :account, Domain.Accounts.Account
    has_many :gateways, Domain.Gateways.Gateway, foreign_key: :group_id
    has_many :tokens, Domain.Gateways.Token, foreign_key: :group_id

    has_many :connections, Domain.Resources.Connection, foreign_key: :gateway_group_id

    field :created_by, Ecto.Enum, values: ~w[identity]a
    belongs_to :created_by_identity, Domain.Auth.Identity

    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
