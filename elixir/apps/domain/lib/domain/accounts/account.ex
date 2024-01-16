defmodule Domain.Accounts.Account do
  use Domain, :schema

  schema "accounts" do
    field :name, :string
    field :slug, :string

    # We mention all schemas here to leverage Ecto compile-time reference checks,
    # because later we will have to shard data by account_id.
    has_many :actors, Domain.Actors.Actor, where: [deleted_at: nil]
    has_many :actor_group_memberships, Domain.Actors.Membership, where: [deleted_at: nil]
    has_many :actor_groups, Domain.Actors.Group, where: [deleted_at: nil]

    has_many :auth_providers, Domain.Auth.Provider, where: [deleted_at: nil]
    has_many :auth_identities, Domain.Auth.Identity, where: [deleted_at: nil]

    has_many :network_addresses, Domain.Network.Address, where: [deleted_at: nil]

    has_many :policies, Domain.Policies.Policy, where: [deleted_at: nil]

    has_many :flows, Domain.Flows.Flow, where: [deleted_at: nil]

    has_many :resources, Domain.Resources.Resource, where: [deleted_at: nil]
    has_many :resource_connections, Domain.Resources.Connection, where: [deleted_at: nil]

    has_many :clients, Domain.Clients.Client, where: [deleted_at: nil]

    has_many :gateways, Domain.Gateways.Gateway, where: [deleted_at: nil]
    has_many :gateway_groups, Domain.Gateways.Group, where: [deleted_at: nil]

    has_many :relays, Domain.Relays.Relay, where: [deleted_at: nil]
    has_many :relay_groups, Domain.Relays.Group, where: [deleted_at: nil]

    has_many :tokens, Domain.Tokens.Token, where: [deleted_at: nil]

    timestamps()
  end
end
