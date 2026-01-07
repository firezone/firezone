defmodule Portal.Repo.Migrations.SplitNetworkAddresses do
  use Ecto.Migration

  def up do
    # Create ipv4_addresses table
    create table(:ipv4_addresses, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:address, :inet, null: false, primary_key: true)

      add(
        :client_id,
        references(:clients,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )

      add(
        :gateway_id,
        references(:gateways,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )

      timestamps(updated_at: false)
    end

    # Create ipv6_addresses table
    create table(:ipv6_addresses, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:address, :inet, null: false, primary_key: true)

      add(
        :client_id,
        references(:clients,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )

      add(
        :gateway_id,
        references(:gateways,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )

      timestamps(updated_at: false)
    end

    # Add check constraints to ensure correct address family
    create(constraint(:ipv4_addresses, :address_is_ipv4, check: "family(address) = 4"))
    create(constraint(:ipv6_addresses, :address_is_ipv6, check: "family(address) = 6"))

    # Ensure each address belongs to exactly one client or gateway
    create(
      constraint(:ipv4_addresses, :belongs_to_client_xor_gateway,
        check:
          "(client_id IS NOT NULL AND gateway_id IS NULL) OR (client_id IS NULL AND gateway_id IS NOT NULL)"
      )
    )

    create(
      constraint(:ipv6_addresses, :belongs_to_client_xor_gateway,
        check:
          "(client_id IS NOT NULL AND gateway_id IS NULL) OR (client_id IS NULL AND gateway_id IS NOT NULL)"
      )
    )

    # Partial indexes for client_id and gateway_id lookups
    create(index(:ipv4_addresses, [:client_id], where: "client_id IS NOT NULL"))
    create(index(:ipv4_addresses, [:gateway_id], where: "gateway_id IS NOT NULL"))
    create(index(:ipv6_addresses, [:client_id], where: "client_id IS NOT NULL"))
    create(index(:ipv6_addresses, [:gateway_id], where: "gateway_id IS NOT NULL"))

    # Drop old foreign key constraints on clients and gateways
    drop(constraint(:clients, "clients_ipv4_fkey"))
    drop(constraint(:clients, "clients_ipv6_fkey"))
    drop(constraint(:gateways, "gateways_ipv4_fkey"))
    drop(constraint(:gateways, "gateways_ipv6_fkey"))

    # Clean up orphaned addresses in network_addresses where the client/gateway no longer exists
    execute("""
    DELETE FROM network_addresses
    WHERE NOT EXISTS (
      SELECT 1 FROM clients
      WHERE clients.account_id = network_addresses.account_id
        AND (clients.ipv4 = network_addresses.address OR clients.ipv6 = network_addresses.address)
    )
    AND NOT EXISTS (
      SELECT 1 FROM gateways
      WHERE gateways.account_id = network_addresses.account_id
        AND (gateways.ipv4 = network_addresses.address OR gateways.ipv6 = network_addresses.address)
    )
    """)

    # Migrate existing client IPv4 addresses
    execute("""
    INSERT INTO ipv4_addresses (account_id, address, client_id, inserted_at)
    SELECT account_id, ipv4, id, inserted_at
    FROM clients
    WHERE ipv4 IS NOT NULL
    """)

    # Migrate existing client IPv6 addresses
    execute("""
    INSERT INTO ipv6_addresses (account_id, address, client_id, inserted_at)
    SELECT account_id, ipv6, id, inserted_at
    FROM clients
    WHERE ipv6 IS NOT NULL
    """)

    # Migrate existing gateway IPv4 addresses
    execute("""
    INSERT INTO ipv4_addresses (account_id, address, gateway_id, inserted_at)
    SELECT account_id, ipv4, id, inserted_at
    FROM gateways
    WHERE ipv4 IS NOT NULL
    """)

    # Migrate existing gateway IPv6 addresses
    execute("""
    INSERT INTO ipv6_addresses (account_id, address, gateway_id, inserted_at)
    SELECT account_id, ipv6, id, inserted_at
    FROM gateways
    WHERE ipv6 IS NOT NULL
    """)

    # Drop ipv4/ipv6 columns from clients and gateways
    alter table(:clients) do
      remove(:ipv4)
      remove(:ipv6)
    end

    alter table(:gateways) do
      remove(:ipv4)
      remove(:ipv6)
    end

    # Drop old network_addresses table
    drop(table(:network_addresses))
  end

  def down do
    # Recreate network_addresses table
    create(table(:network_addresses, primary_key: false)) do
      add(:type, :string, null: false)
      add(:address, :inet, null: false, primary_key: true)
      add(:account_id, references(:accounts, type: :binary_id), null: false, primary_key: true)

      timestamps(updated_at: false)
    end

    # Migrate addresses back to network_addresses
    execute("""
    INSERT INTO network_addresses (account_id, address, type, inserted_at)
    SELECT account_id, address, 'ipv4', inserted_at
    FROM ipv4_addresses
    """)

    execute("""
    INSERT INTO network_addresses (account_id, address, type, inserted_at)
    SELECT account_id, address, 'ipv6', inserted_at
    FROM ipv6_addresses
    """)

    # Recreate ipv4/ipv6 columns on clients
    alter table(:clients) do
      add(:ipv4, :inet)
      add(:ipv6, :inet)
    end

    # Recreate ipv4/ipv6 columns on gateways
    alter table(:gateways) do
      add(:ipv4, :inet)
      add(:ipv6, :inet)
    end

    # Migrate addresses back to clients
    execute("""
    UPDATE clients SET ipv4 = ipv4_addresses.address
    FROM ipv4_addresses
    WHERE ipv4_addresses.client_id = clients.id
    """)

    execute("""
    UPDATE clients SET ipv6 = ipv6_addresses.address
    FROM ipv6_addresses
    WHERE ipv6_addresses.client_id = clients.id
    """)

    # Migrate addresses back to gateways
    execute("""
    UPDATE gateways SET ipv4 = ipv4_addresses.address
    FROM ipv4_addresses
    WHERE ipv4_addresses.gateway_id = gateways.id
    """)

    execute("""
    UPDATE gateways SET ipv6 = ipv6_addresses.address
    FROM ipv6_addresses
    WHERE ipv6_addresses.gateway_id = gateways.id
    """)

    # Recreate foreign key constraints on clients to network_addresses
    alter table(:clients) do
      modify(
        :ipv4,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )

      modify(
        :ipv6,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )
    end

    # Recreate foreign key constraints on gateways to network_addresses
    alter table(:gateways) do
      modify(
        :ipv4,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )

      modify(
        :ipv6,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id],
          on_delete: :delete_all
        )
      )
    end

    # Drop new tables
    drop(table(:ipv4_addresses))
    drop(table(:ipv6_addresses))
  end
end
