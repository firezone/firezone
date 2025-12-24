defmodule Portal.Repo.Migrations.AddAccountDeletionCascade do
  use Ecto.Migration

  def change do
    execute("""
    ALTER TABLE "actor_group_memberships"
    DROP CONSTRAINT "actor_group_memberships_account_id_fkey",
    ADD CONSTRAINT "actor_group_memberships_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "actors"
    DROP CONSTRAINT "actors_account_id_fkey",
    ADD CONSTRAINT "actors_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "auth_identities"
    DROP CONSTRAINT "auth_identities_account_id_fkey",
    ADD CONSTRAINT "auth_identities_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "auth_providers"
    DROP CONSTRAINT "auth_providers_account_id_fkey",
    ADD CONSTRAINT "auth_providers_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "clients"
    DROP CONSTRAINT "devices_account_id_fkey",
    ADD CONSTRAINT "devices_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "configurations"
    DROP CONSTRAINT "configurations_account_id_fkey",
    ADD CONSTRAINT "configurations_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "gateway_groups"
    DROP CONSTRAINT "gateway_groups_account_id_fkey",
    ADD CONSTRAINT "gateway_groups_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "gateways"
    DROP CONSTRAINT "gateways_account_id_fkey",
    ADD CONSTRAINT "gateways_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "network_addresses"
    DROP CONSTRAINT "network_addresses_account_id_fkey",
    ADD CONSTRAINT "network_addresses_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "policies"
    DROP CONSTRAINT "policies_account_id_fkey",
    ADD CONSTRAINT "policies_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "relay_groups"
    DROP CONSTRAINT "relay_groups_account_id_fkey",
    ADD CONSTRAINT "relay_groups_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "relays"
    DROP CONSTRAINT "relays_account_id_fkey",
    ADD CONSTRAINT "relays_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "resource_connections"
    DROP CONSTRAINT "resource_connections_account_id_fkey",
    ADD CONSTRAINT "resource_connections_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)

    execute("""
    ALTER TABLE "resources"
    DROP CONSTRAINT "resources_account_id_fkey",
    ADD CONSTRAINT "resources_account_id_fkey"
    FOREIGN KEY ("account_id")
    REFERENCES "accounts" ("id") ON DELETE CASCADE;
    """)
  end
end
