defmodule Domain.Flows.Flow do
  use Domain, :schema

  schema "flows" do
    belongs_to :policy, Domain.Policies.Policy
    belongs_to :client, Domain.Clients.Client
    belongs_to :gateway, Domain.Gateways.Gateway
    belongs_to :resource, Domain.Resources.Resource
    belongs_to :token, Domain.Tokens.Token
    belongs_to :actor_group_membership, Domain.Actors.Membership

    belongs_to :account, Domain.Accounts.Account

    field :client_remote_ip, Domain.Types.IP
    field :client_user_agent, :string

    field :gateway_remote_ip, Domain.Types.IP

    timestamps(updated_at: false)
  end
end
