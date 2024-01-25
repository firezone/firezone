defmodule Domain.Flows.Flow do
  use Domain, :schema

  schema "flows" do
    belongs_to :policy, Domain.Policies.Policy
    belongs_to :client, Domain.Clients.Client
    belongs_to :gateway, Domain.Gateways.Gateway
    belongs_to :resource, Domain.Resources.Resource
    belongs_to :token, Domain.Tokens.Token

    belongs_to :account, Domain.Accounts.Account

    field :client_remote_ip, Domain.Types.IP
    field :client_user_agent, :string

    field :gateway_remote_ip, Domain.Types.IP

    field :expires_at, :utc_datetime_usec
    timestamps(updated_at: false)
  end
end
