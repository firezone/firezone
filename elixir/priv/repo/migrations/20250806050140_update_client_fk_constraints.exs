defmodule Portal.Repo.Migrations.UpdateClientFkConstraints do
  use Ecto.Migration

  def up do
    # Rename Identity FK and add ON DELETE CASCADE
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_identity_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT clients_identity_id_fkey
    FOREIGN KEY (identity_id)
    REFERENCES auth_identities(id)
    ON DELETE CASCADE
    """)

    # Rename Actor FK and add ON DELETE CASCADE
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_actor_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT clients_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES actors(id)
    ON DELETE CASCADE
    """)

    # Rename Account FK
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_account_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT clients_account_id_fkey
    FOREIGN KEY (account_id)
    REFERENCES accounts(id)
    ON DELETE CASCADE
    """)

    # Rename IPv4 FK
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_ipv4_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT clients_ipv4_fkey
    FOREIGN KEY (ipv4, account_id)
    REFERENCES network_addresses(address, account_id)
    ON DELETE NO ACTION
    """)

    # Rename IPv6 FK
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_ipv6_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT clients_ipv6_fkey
    FOREIGN KEY (ipv6, account_id)
    REFERENCES network_addresses(address, account_id)
    ON DELETE NO ACTION
    """)

    # Rename Primary Key Index
    execute("""
      ALTER INDEX devices_pkey RENAME TO clients_pkey;
    """)
  end

  def down do
    # Undo rename Identity FK and add ON DELETE CASCADE
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_identity_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_identity_id_fkey
    FOREIGN KEY (identity_id)
    REFERENCES auth_identities(id)
    ON DELETE NO ACTION
    """)

    # Undo rename Actor FK and add ON DELETE CASCADE
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_actor_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES actors(id)
    ON DELETE NO ACTION
    """)

    # Undo rename Account FK
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_account_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_account_id_fkey
    FOREIGN KEY (account_id)
    REFERENCES accounts(id)
    ON DELETE NO ACTION
    """)

    # Undo rename IPv4 FK
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_ipv4_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_ipv4_fkey
    FOREIGN KEY (ipv4, account_id)
    REFERENCES network_addresses(address, account_id)
    ON DELETE NO ACTION
    """)

    # Undo rename IPv6 FK
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS clients_ipv6_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_ipv6_fkey
    FOREIGN KEY (ipv6, account_id)
    REFERENCES network_addresses(address, account_id)
    ON DELETE NO ACTION
    """)

    # Undo rename Primary Key Index
    execute("""
      ALTER INDEX clients_pkey RENAME TO devices_pkey;
    """)
  end
end
