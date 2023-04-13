defmodule Domain.Gateways.Token do
  use Domain, :schema

  schema "gateway_tokens" do
    field :value, :string, virtual: true
    field :hash, :string

    belongs_to :account, Domain.Accounts.Account
    belongs_to :group, Domain.Gateways.Group

    field :deleted_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
