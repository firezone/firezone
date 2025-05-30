defmodule Domain.Resources.Connection do
  use Domain, :schema

  @primary_key false
  schema "resource_connections" do
    belongs_to :resource, Domain.Resources.Resource, primary_key: true
    belongs_to :gateway_group, Domain.Gateways.Group, primary_key: true

    field :created_by, Ecto.Enum, values: ~w[actor identity system]a
    field :created_by_subject, :map

    belongs_to :account, Domain.Accounts.Account
  end
end
