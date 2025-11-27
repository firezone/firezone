defmodule Domain.Resources.Connection do
  use Domain, :schema

  @type t :: %__MODULE__{
          resource_id: Ecto.UUID.t(),
          gateway_group_id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t()
        }

  @primary_key false
  schema "resource_connections" do
    belongs_to :resource, Domain.Resource, primary_key: true
    belongs_to :gateway_group, Domain.Gateways.Group, primary_key: true

    belongs_to :account, Domain.Accounts.Account
  end
end
