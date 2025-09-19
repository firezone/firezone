defmodule Domain.Repo.Migrations.AddNonCompositeIndexesForCascadeFks do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # Indexes for actor_groups table CASCADE foreign key
    create_if_not_exists(index(:actor_groups, [:provider_id], concurrently: true))

    # Indexes for auth_identities table CASCADE foreign keys
    create_if_not_exists(index(:auth_identities, [:actor_id], concurrently: true))
    create_if_not_exists(index(:auth_identities, [:provider_id], concurrently: true))

    # Indexes for clients table CASCADE foreign keys
    create_if_not_exists(index(:clients, [:actor_id], concurrently: true))
    create_if_not_exists(index(:clients, [:identity_id], concurrently: true))

    # Indexes for flows table CASCADE foreign keys
    create_if_not_exists(index(:flows, [:actor_group_membership_id], concurrently: true))
    create_if_not_exists(index(:flows, [:client_id], concurrently: true))
    create_if_not_exists(index(:flows, [:gateway_id], concurrently: true))
    create_if_not_exists(index(:flows, [:policy_id], concurrently: true))
    create_if_not_exists(index(:flows, [:resource_id], concurrently: true))
    create_if_not_exists(index(:flows, [:token_id], concurrently: true))

    # Indexes for gateways table CASCADE foreign key
    create_if_not_exists(index(:gateways, [:group_id], concurrently: true))

    # Index for policies table CASCADE foreign key
    create_if_not_exists(index(:policies, [:replaced_by_policy_id], concurrently: true))

    # Indexes for relays table CASCADE foreign keys
    create_if_not_exists(index(:relays, [:account_id], concurrently: true))
    create_if_not_exists(index(:relays, [:group_id], concurrently: true))

    # Index for resources table CASCADE foreign key
    create_if_not_exists(index(:resources, [:replaced_by_resource_id], concurrently: true))

    # Indexes for resource_connections table CASCADE foreign keys
    create_if_not_exists(index(:resource_connections, [:resource_id], concurrently: true))
    create_if_not_exists(index(:resource_connections, [:gateway_group_id], concurrently: true))

    # Indexes for tokens table CASCADE foreign keys
    create_if_not_exists(index(:tokens, [:relay_group_id], concurrently: true))
    create_if_not_exists(index(:tokens, [:gateway_group_id], concurrently: true))
    create_if_not_exists(index(:tokens, [:actor_id], concurrently: true))
    create_if_not_exists(index(:tokens, [:identity_id], concurrently: true))
  end

  def down do
    # Drop indexes concurrently using raw SQL for non-blocking rollbacks
    execute("DROP INDEX CONCURRENTLY IF EXISTS actor_groups_provider_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS auth_identities_actor_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS auth_identities_provider_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS clients_actor_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS clients_identity_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS flows_actor_group_membership_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS flows_client_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS flows_gateway_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS flows_policy_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS flows_resource_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS flows_token_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS gateways_group_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS policies_replaced_by_policy_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS relays_account_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS relays_group_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS resources_replaced_by_resource_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS resource_connections_resource_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS resource_connections_gateway_group_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS tokens_relay_group_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS tokens_gateway_group_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS tokens_actor_id_index")
    execute("DROP INDEX CONCURRENTLY IF EXISTS tokens_identity_id_index")
  end
end
