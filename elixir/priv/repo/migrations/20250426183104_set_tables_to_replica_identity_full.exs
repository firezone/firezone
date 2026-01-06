defmodule Portal.Repo.Migrations.SetTablesToReplicaIdentityFull do
  use Ecto.Migration

  @relations ~w[
    accounts
    actor_group_memberships
    actor_groups
    actors
    auth_identities
    auth_providers
    clients
    flow_activities
    flows
    gateway_groups
    gateways
    policies
    relay_groups
    relays
    resource_connections
    resources
    tokens
  ]

  def change do
    for relation <- @relations do
      execute("ALTER TABLE #{relation} REPLICA IDENTITY FULL")
    end
  end
end
