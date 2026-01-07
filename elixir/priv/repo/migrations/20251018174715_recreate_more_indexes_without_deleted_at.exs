defmodule Portal.Repo.Migrations.RecreateMoreIndexesWithoutDeletedAt do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # Accounts
    drop_if_exists(
      index(:accounts, [:slug],
        name: :accounts_slug_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:accounts, [:slug],
        name: :accounts_slug_index,
        concurrently: true
      )
    )

    # Actor Groups - simple account_id index
    drop_if_exists(
      index(:actor_groups, [:account_id],
        name: :actor_groups_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actor_groups, [:account_id],
        name: :actor_groups_account_id_index,
        concurrently: true
      )
    )

    # Actor Groups - account_id_name unique index with complex WHERE clause
    execute("DROP INDEX CONCURRENTLY IF EXISTS actor_groups_account_id_name_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS actor_groups_account_id_name_index
    ON actor_groups (account_id, name)
    WHERE provider_id IS NULL AND provider_identifier IS NULL
    """)

    # Actors - account_id_type index
    drop_if_exists(
      index(:actors, [:account_id, :type],
        name: :index_actors_on_account_id_and_type,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actors, [:account_id, :type],
        name: :index_actors_on_account_id_and_type,
        concurrently: true
      )
    )

    # Actors - account_id index
    drop_if_exists(
      index(:actors, [:account_id],
        name: :actors_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actors, [:account_id],
        name: :actors_account_id_index,
        concurrently: true
      )
    )

    # Auth Providers - OIDC adapter index
    execute("DROP INDEX CONCURRENTLY IF EXISTS auth_providers_account_id_oidc_adapter_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS auth_providers_account_id_oidc_adapter_index
    ON auth_providers (account_id, adapter, (adapter_config ->> 'client_id'))
    WHERE adapter = 'openid_connect'
    """)

    # Auth Providers - adapter index for specific adapters
    execute("DROP INDEX CONCURRENTLY IF EXISTS auth_providers_account_id_adapter_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS auth_providers_account_id_adapter_index
    ON auth_providers (account_id, adapter)
    WHERE adapter IN ('email', 'userpass', 'token')
    """)

    # Auth Providers - unique_account_adapter_index for other adapters
    execute("DROP INDEX CONCURRENTLY IF EXISTS unique_account_adapter_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS unique_account_adapter_index
    ON auth_providers (account_id, adapter)
    WHERE adapter IN ('mock', 'google_workspace', 'okta', 'jumpcloud', 'microsoft_entra')
    """)

    # Auth Providers - account_id index
    drop_if_exists(
      index(:auth_providers, [:account_id],
        name: :auth_providers_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:auth_providers, [:account_id],
        name: :auth_providers_account_id_index,
        concurrently: true
      )
    )

    # Auth Providers - assigned_default_at index
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS auth_providers_account_id_assigned_default_at_index"
    )

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS auth_providers_account_id_assigned_default_at_index
    ON auth_providers (account_id)
    WHERE disabled_at IS NULL AND assigned_default_at IS NOT NULL
    """)

    # Auth Providers - adapter index
    execute("DROP INDEX CONCURRENTLY IF EXISTS index_auth_providers_on_adapter")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS index_auth_providers_on_adapter
    ON auth_providers (adapter)
    WHERE disabled_at IS NULL
    """)

    # Clients - account_id_actor_id_public_key unique index
    drop_if_exists(
      index(:clients, [:account_id, :actor_id, :public_key],
        name: :clients_account_id_actor_id_public_key_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :actor_id, :public_key],
        name: :clients_account_id_actor_id_public_key_index,
        concurrently: true
      )
    )

    # Clients - account_id_ipv6 unique index
    drop_if_exists(
      index(:clients, [:account_id, :ipv6],
        name: :clients_account_id_ipv6_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :ipv6],
        name: :clients_account_id_ipv6_index,
        concurrently: true
      )
    )

    # Clients - account_id_ipv4 unique index
    drop_if_exists(
      index(:clients, [:account_id, :ipv4],
        name: :clients_account_id_ipv4_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :ipv4],
        name: :clients_account_id_ipv4_index,
        concurrently: true
      )
    )

    # Clients - account_id_last_seen_at index with DESC ordering
    execute("DROP INDEX CONCURRENTLY IF EXISTS clients_account_id_last_seen_at_index")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS clients_account_id_last_seen_at_index
    ON clients (account_id, last_seen_at DESC)
    """)

    # Clients - account_id index
    drop_if_exists(
      index(:clients, [:account_id],
        name: :clients_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:clients, [:account_id],
        name: :clients_account_id_index,
        concurrently: true
      )
    )

    # Gateway Groups
    drop_if_exists(
      index(:gateway_groups, [:account_id, :name, :managed_by],
        name: :gateway_groups_account_id_name_managed_by_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateway_groups, [:account_id, :name, :managed_by],
        name: :gateway_groups_account_id_name_managed_by_index,
        concurrently: true
      )
    )

    # Gateways - account_id_ipv4 unique index
    drop_if_exists(
      index(:gateways, [:account_id, :ipv4],
        name: :gateways_account_id_ipv4_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :ipv4],
        name: :gateways_account_id_ipv4_index,
        concurrently: true
      )
    )

    # Gateways - account_id_ipv6 unique index
    drop_if_exists(
      index(:gateways, [:account_id, :ipv6],
        name: :gateways_account_id_ipv6_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :ipv6],
        name: :gateways_account_id_ipv6_index,
        concurrently: true
      )
    )

    # Gateways - account_id_public_key unique index
    drop_if_exists(
      index(:gateways, [:account_id, :public_key],
        name: :gateways_account_id_public_key_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :public_key],
        name: :gateways_account_id_public_key_index,
        concurrently: true
      )
    )

    # Policies
    drop_if_exists(
      index(:policies, [:account_id, :resource_id, :actor_group_id],
        name: :policies_account_id_resource_id_actor_group_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:policies, [:account_id, :resource_id, :actor_group_id],
        name: :policies_account_id_resource_id_actor_group_id_index,
        concurrently: true
      )
    )

    # Relay Groups - account_id_name unique index
    drop_if_exists(
      index(:relay_groups, [:account_id, :name],
        name: :relay_groups_account_id_name_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:relay_groups, [:account_id, :name],
        name: :relay_groups_account_id_name_index,
        concurrently: true
      )
    )

    # Relay Groups - name unique index with account_id IS NULL
    execute("DROP INDEX CONCURRENTLY IF EXISTS relay_groups_name_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS relay_groups_name_index
    ON relay_groups (name)
    WHERE account_id IS NULL
    """)

    # Resources - account_id_name index
    drop_if_exists(
      index(:resources, [:account_id, :name],
        name: :resources_account_id_name_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:resources, [:account_id, :name],
        name: :resources_account_id_name_index,
        concurrently: true
      )
    )

    # Tokens - account_id_type index
    drop_if_exists(
      index(:tokens, [:account_id, :type],
        name: :tokens_account_id_type_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:tokens, [:account_id, :type],
        name: :tokens_account_id_type_index,
        concurrently: true
      )
    )
  end

  def down do
    # Accounts
    drop_if_exists(
      index(:accounts, [:slug],
        name: :accounts_slug_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:accounts, [:slug],
        name: :accounts_slug_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Actor Groups - simple account_id index
    drop_if_exists(
      index(:actor_groups, [:account_id],
        name: :actor_groups_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actor_groups, [:account_id],
        name: :actor_groups_account_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Actor Groups - account_id_name unique index with complex WHERE clause
    execute("DROP INDEX CONCURRENTLY IF EXISTS actor_groups_account_id_name_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS actor_groups_account_id_name_index
    ON actor_groups (account_id, name)
    WHERE deleted_at IS NULL AND provider_id IS NULL AND provider_identifier IS NULL
    """)

    # Actors - account_id_type index
    drop_if_exists(
      index(:actors, [:account_id, :type],
        name: :index_actors_on_account_id_and_type,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actors, [:account_id, :type],
        name: :index_actors_on_account_id_and_type,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Actors - account_id index
    drop_if_exists(
      index(:actors, [:account_id],
        name: :actors_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:actors, [:account_id],
        name: :actors_account_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Auth Providers - OIDC adapter index
    execute("DROP INDEX CONCURRENTLY IF EXISTS auth_providers_account_id_oidc_adapter_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS auth_providers_account_id_oidc_adapter_index
    ON auth_providers (account_id, adapter, (adapter_config ->> 'client_id'))
    WHERE deleted_at IS NULL AND adapter = 'openid_connect'
    """)

    # Auth Providers - adapter index for specific adapters
    execute("DROP INDEX CONCURRENTLY IF EXISTS auth_providers_account_id_adapter_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS auth_providers_account_id_adapter_index
    ON auth_providers (account_id, adapter)
    WHERE deleted_at IS NULL AND adapter IN ('email', 'userpass', 'token')
    """)

    # Auth Providers - unique_account_adapter_index for other adapters
    execute("DROP INDEX CONCURRENTLY IF EXISTS unique_account_adapter_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS unique_account_adapter_index
    ON auth_providers (account_id, adapter)
    WHERE deleted_at IS NULL AND adapter IN ('mock', 'google_workspace', 'okta', 'jumpcloud', 'microsoft_entra')
    """)

    # Auth Providers - account_id index
    drop_if_exists(
      index(:auth_providers, [:account_id],
        name: :auth_providers_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:auth_providers, [:account_id],
        name: :auth_providers_account_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Auth Providers - assigned_default_at index
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS auth_providers_account_id_assigned_default_at_index"
    )

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS auth_providers_account_id_assigned_default_at_index
    ON auth_providers (account_id)
    WHERE deleted_at IS NULL AND disabled_at IS NULL AND assigned_default_at IS NOT NULL
    """)

    # Auth Providers - adapter index
    execute("DROP INDEX CONCURRENTLY IF EXISTS index_auth_providers_on_adapter")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS index_auth_providers_on_adapter
    ON auth_providers (adapter)
    WHERE disabled_at IS NULL AND deleted_at IS NULL
    """)

    # Clients - account_id_actor_id_public_key unique index
    drop_if_exists(
      index(:clients, [:account_id, :actor_id, :public_key],
        name: :clients_account_id_actor_id_public_key_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :actor_id, :public_key],
        name: :clients_account_id_actor_id_public_key_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Clients - account_id_ipv6 unique index
    drop_if_exists(
      index(:clients, [:account_id, :ipv6],
        name: :clients_account_id_ipv6_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :ipv6],
        name: :clients_account_id_ipv6_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Clients - account_id_ipv4 unique index
    drop_if_exists(
      index(:clients, [:account_id, :ipv4],
        name: :clients_account_id_ipv4_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :ipv4],
        name: :clients_account_id_ipv4_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Clients - account_id_last_seen_at index with DESC ordering
    execute("DROP INDEX CONCURRENTLY IF EXISTS clients_account_id_last_seen_at_index")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS clients_account_id_last_seen_at_index
    ON clients (account_id, last_seen_at DESC)
    WHERE deleted_at IS NULL
    """)

    # Clients - account_id index
    drop_if_exists(
      index(:clients, [:account_id],
        name: :clients_account_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:clients, [:account_id],
        name: :clients_account_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Gateway Groups
    drop_if_exists(
      index(:gateway_groups, [:account_id, :name, :managed_by],
        name: :gateway_groups_account_id_name_managed_by_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateway_groups, [:account_id, :name, :managed_by],
        name: :gateway_groups_account_id_name_managed_by_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Gateways - account_id_ipv4 unique index
    drop_if_exists(
      index(:gateways, [:account_id, :ipv4],
        name: :gateways_account_id_ipv4_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :ipv4],
        name: :gateways_account_id_ipv4_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Gateways - account_id_ipv6 unique index
    drop_if_exists(
      index(:gateways, [:account_id, :ipv6],
        name: :gateways_account_id_ipv6_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :ipv6],
        name: :gateways_account_id_ipv6_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Gateways - account_id_public_key unique index
    drop_if_exists(
      index(:gateways, [:account_id, :public_key],
        name: :gateways_account_id_public_key_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :public_key],
        name: :gateways_account_id_public_key_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Policies
    drop_if_exists(
      index(:policies, [:account_id, :resource_id, :actor_group_id],
        name: :policies_account_id_resource_id_actor_group_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:policies, [:account_id, :resource_id, :actor_group_id],
        name: :policies_account_id_resource_id_actor_group_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Relay Groups - account_id_name unique index
    drop_if_exists(
      index(:relay_groups, [:account_id, :name],
        name: :relay_groups_account_id_name_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:relay_groups, [:account_id, :name],
        name: :relay_groups_account_id_name_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Relay Groups - name unique index with account_id IS NULL
    execute("DROP INDEX CONCURRENTLY IF EXISTS relay_groups_name_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS relay_groups_name_index
    ON relay_groups (name)
    WHERE deleted_at IS NULL AND account_id IS NULL
    """)

    # Resources - account_id_name index
    drop_if_exists(
      index(:resources, [:account_id, :name],
        name: :resources_account_id_name_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:resources, [:account_id, :name],
        name: :resources_account_id_name_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Tokens - account_id_type index
    drop_if_exists(
      index(:tokens, [:account_id, :type],
        name: :tokens_account_id_type_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      index(:tokens, [:account_id, :type],
        name: :tokens_account_id_type_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )
  end
end
