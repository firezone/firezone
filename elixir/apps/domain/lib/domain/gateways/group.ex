defmodule Domain.Gateways.Group do
  use Domain, :schema

  schema "gateway_groups" do
    field :name, :string

    field :managed_by, Ecto.Enum, values: ~w[account system]a

    belongs_to :account, Domain.Accounts.Account
    # TODO: Remove `where` after `deleted_at` column is remove
    has_many :gateways, Domain.Gateways.Gateway, foreign_key: :group_id, where: [deleted_at: nil]

    # TODO: Remove `where` after `deleted_at` column is remove
    has_many :tokens, Domain.Tokens.Token,
      foreign_key: :gateway_group_id,
      where: [deleted_at: nil]

    has_many :connections, Domain.Resources.Connection, foreign_key: :gateway_group_id

    field :created_by, Ecto.Enum, values: ~w[actor identity system]a
    field :created_by_subject, :map

    # TODO: Remove field after soft deletion is removed
    field :deleted_at, :utc_datetime_usec
    timestamps()
  end
end
