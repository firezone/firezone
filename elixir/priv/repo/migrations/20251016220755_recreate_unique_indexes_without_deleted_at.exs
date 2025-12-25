defmodule Portal.Repo.Migrations.RecreateUniqueIndexesWithoutDeletedAt do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    # Clients
    drop_if_exists(
      index(:clients, [:account_id, :actor_id, :external_id],
        name: :clients_account_id_actor_id_external_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :actor_id, :external_id],
        name: :clients_account_id_actor_id_external_id_index,
        concurrently: true
      )
    )

    # Gateways
    drop_if_exists(
      index(:gateways, [:account_id, :group_id, :external_id],
        name: :gateways_account_id_group_id_external_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :group_id, :external_id],
        name: :gateways_account_id_group_id_external_id_index,
        concurrently: true
      )
    )

    # Global Relays (requires raw SQL due to COALESCE)
    execute("DROP INDEX CONCURRENTLY IF EXISTS global_relays_unique_address_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS global_relays_unique_address_index
    ON relays (COALESCE(ipv4, ipv6), port)
    WHERE account_id IS NULL
    """)

    # Account Relays (requires raw SQL due to COALESCE)
    execute("DROP INDEX CONCURRENTLY IF EXISTS relays_unique_address_index")

    execute("""
    CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS relays_unique_address_index
    ON relays (account_id, COALESCE(ipv4, ipv6), port)
    WHERE account_id IS NOT NULL
    """)

    # Auth Identities - provider_identifier unique index
    drop_if_exists(
      index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        name: :auth_identities_account_id_provider_id_provider_identifier_idx,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        name: :auth_identities_account_id_provider_id_provider_identifier_idx,
        concurrently: true
      )
    )

    # Auth Identities - email unique index
    drop_if_exists(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx,
        concurrently: true
      )
    )
  end

  def down do
    # Clients
    drop_if_exists(
      index(:clients, [:account_id, :actor_id, :external_id],
        name: :clients_account_id_actor_id_external_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:clients, [:account_id, :actor_id, :external_id],
        name: :clients_account_id_actor_id_external_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Gateways
    drop_if_exists(
      index(:gateways, [:account_id, :group_id, :external_id],
        name: :gateways_account_id_group_id_external_id_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:gateways, [:account_id, :group_id, :external_id],
        name: :gateways_account_id_group_id_external_id_index,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Global Relays (requires raw SQL due to COALESCE)
    execute("DROP INDEX IF EXISTS global_relays_unique_address_index")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS global_relays_unique_address_index
    ON relays (COALESCE(ipv4, ipv6), port)
    WHERE deleted_at IS NULL AND account_id IS NULL
    """)

    # Account Relays (requires raw SQL due to COALESCE)
    execute("DROP INDEX IF EXISTS relays_unique_address_index")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS relays_unique_address_index
    ON relays (account_id, COALESCE(ipv4, ipv6), port)
    WHERE deleted_at IS NULL AND account_id IS NOT NULL
    """)

    # Auth Identities - provider_identifier unique index
    drop_if_exists(
      index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        name: :auth_identities_account_id_provider_id_provider_identifier_idx,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        name: :auth_identities_account_id_provider_id_provider_identifier_idx,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )

    # Auth Identities - email unique index
    drop_if_exists(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx,
        where: "deleted_at IS NULL",
        concurrently: true
      )
    )
  end
end
