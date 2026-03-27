defmodule Portal.Repo.Migrations.CreateDevicesTable do
  use Ecto.Migration

  def up do
    create table(:devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :uuid, null: false, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:type, :string, null: false)

      add(:firezone_id, :string, size: 255, null: false)
      add(:name, :string, null: false)
      add(:psk_base, :bytea, null: false, default: fragment("gen_random_bytes(32)"))

      add(:ipv4, :inet, null: false)
      add(:ipv6, :inet, null: false)

      # Client-only fields
      add(
        :actor_id,
        references(:actors, type: :binary_id, with: [account_id: :account_id]),
        null: true
      )

      add(:device_serial, :string)
      add(:device_uuid, :string)
      add(:identifier_for_vendor, :string)
      add(:firebase_installation_id, :string)
      add(:verified_at, :utc_datetime_usec)

      # Gateway-only fields
      add(
        :site_id,
        references(:sites, type: :binary_id, with: [account_id: :account_id]),
        null: true
      )

      timestamps(type: :utc_datetime_usec)
    end

    # Type check constraint
    create(constraint(:devices, :devices_type_check, check: "type IN ('client', 'gateway')"))

    # Client fields validation: clients must have actor_id, must not have site_id
    create(
      constraint(:devices, :device_type_client_fields,
        check: "type != 'client' OR (actor_id IS NOT NULL AND site_id IS NULL)"
      )
    )

    # Gateway fields validation: gateways must have site_id, must not have actor_id
    create(
      constraint(:devices, :device_type_gateway_fields,
        check: "type != 'gateway' OR (site_id IS NOT NULL AND actor_id IS NULL)"
      )
    )

    # Indexes (non-concurrent, in same migration)
    create(
      unique_index(:devices, [:account_id, :actor_id, :firezone_id],
        where: "type = 'client'",
        name: :devices_account_id_actor_id_firezone_id_index
      )
    )

    create(
      unique_index(:devices, [:account_id, :site_id, :firezone_id],
        where: "type = 'gateway'",
        name: :devices_account_id_site_id_firezone_id_index
      )
    )

    create(
      index(:devices, [:account_id, :actor_id],
        where: "actor_id IS NOT NULL",
        name: :devices_account_id_actor_id_index
      )
    )

    create(
      index(:devices, [:account_id, :site_id],
        where: "site_id IS NOT NULL",
        name: :devices_account_id_site_id_index
      )
    )

    create(unique_index(:devices, [:account_id, :ipv4], name: :devices_account_id_ipv4_index))

    create(unique_index(:devices, [:account_id, :ipv6], name: :devices_account_id_ipv6_index))

    create(
      unique_index(:devices, [:account_id, :id, :type], name: :devices_account_id_id_type_index)
    )

    execute("""
    CREATE OR REPLACE FUNCTION find_available_device_address(
      p_account_id uuid,
      p_type text,
      p_cidr cidr
    ) RETURNS inet
    LANGUAGE plpgsql
    AS $$
    DECLARE
      v_base_address inet;
      v_last_address inet;
      v_total_addresses bigint;
      v_start_offset bigint;
      v_current_offset bigint;
      v_candidate inet;
    BEGIN
      PERFORM pg_advisory_xact_lock(
        ('x' || substr(md5(p_account_id::text || ':' || p_type), 1, 16))::bit(64)::bigint
      );

      v_base_address := host(p_cidr)::inet;
      v_last_address := host(broadcast(p_cidr))::inet - 1;
      v_total_addresses := (v_last_address - v_base_address)::bigint;

      IF p_type NOT IN ('ipv4', 'ipv6') THEN
        RAISE EXCEPTION 'Invalid address type: %. Must be ipv4 or ipv6', p_type
          USING ERRCODE = 'P0001';
      END IF;

      IF v_total_addresses < 1 THEN
        RAISE EXCEPTION 'Address pool % has no allocatable host addresses', p_cidr
          USING ERRCODE = '22023';
      END IF;

      v_start_offset := floor(random() * v_total_addresses)::bigint + 1;
      v_current_offset := v_start_offset;

      LOOP
        v_candidate := v_base_address + v_current_offset;

        IF p_type = 'ipv4' THEN
          PERFORM 1
          FROM devices d
          WHERE d.account_id = p_account_id
            AND d.ipv4 = v_candidate;
        ELSE
          PERFORM 1
          FROM devices d
          WHERE d.account_id = p_account_id
            AND d.ipv6 = v_candidate;
        END IF;

        IF NOT FOUND THEN
          RETURN v_candidate;
        END IF;

        v_current_offset := v_current_offset + 1;

        IF v_current_offset > v_total_addresses THEN
          v_current_offset := 1;
        END IF;

        IF v_current_offset = v_start_offset THEN
          RAISE EXCEPTION 'Address pool exhausted for account %', p_account_id
            USING ERRCODE = '53400';
        END IF;
      END LOOP;
    END;
    $$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION assign_device_network_addresses()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      v_ipv4_cidr constant cidr := '100.64.0.0/11';
      v_ipv6_cidr constant cidr := 'fd00:2021:1111::/107';
    BEGIN
      IF NEW.ipv4 IS NULL THEN
        NEW.ipv4 := find_available_device_address(NEW.account_id, 'ipv4', v_ipv4_cidr);
      END IF;

      IF NEW.ipv6 IS NULL THEN
        NEW.ipv6 := find_available_device_address(NEW.account_id, 'ipv6', v_ipv6_cidr);
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    execute("""
    CREATE TRIGGER assign_device_network_addresses
    BEFORE INSERT ON devices
    FOR EACH ROW
    WHEN (NEW.ipv4 IS NULL OR NEW.ipv6 IS NULL)
    EXECUTE FUNCTION assign_device_network_addresses()
    """)

    # Populate devices from clients with their IPs
    execute("""
    INSERT INTO devices (account_id, id, type, firezone_id, name, psk_base, actor_id,
      device_serial, device_uuid, identifier_for_vendor, firebase_installation_id,
      verified_at, ipv4, ipv6, inserted_at, updated_at)
    SELECT c.account_id, c.id, 'client', c.external_id, c.name, c.psk_base, c.actor_id,
      c.device_serial, c.device_uuid, c.identifier_for_vendor, c.firebase_installation_id,
      c.verified_at, ipv4.address, ipv6.address, c.inserted_at, c.updated_at
    FROM clients c
    LEFT JOIN LATERAL (
      SELECT ipv4.address
      FROM ipv4_addresses ipv4
      WHERE ipv4.client_id = c.id
        AND ipv4.account_id = c.account_id
      ORDER BY ipv4.inserted_at DESC, ipv4.address DESC
      LIMIT 1
    ) ipv4 ON TRUE
    LEFT JOIN LATERAL (
      SELECT ipv6.address
      FROM ipv6_addresses ipv6
      WHERE ipv6.client_id = c.id
        AND ipv6.account_id = c.account_id
      ORDER BY ipv6.inserted_at DESC, ipv6.address DESC
      LIMIT 1
    ) ipv6 ON TRUE
    """)

    # Populate devices from gateways with their IPs
    execute("""
    INSERT INTO devices (account_id, id, type, firezone_id, name, psk_base, site_id,
      ipv4, ipv6, inserted_at, updated_at)
    SELECT g.account_id, g.id, 'gateway', g.external_id, g.name, g.psk_base, g.site_id,
      ipv4.address, ipv6.address, g.inserted_at, g.updated_at
    FROM gateways g
    LEFT JOIN LATERAL (
      SELECT ipv4.address
      FROM ipv4_addresses ipv4
      WHERE ipv4.gateway_id = g.id
        AND ipv4.account_id = g.account_id
      ORDER BY ipv4.inserted_at DESC, ipv4.address DESC
      LIMIT 1
    ) ipv4 ON TRUE
    LEFT JOIN LATERAL (
      SELECT ipv6.address
      FROM ipv6_addresses ipv6
      WHERE ipv6.gateway_id = g.id
        AND ipv6.account_id = g.account_id
      ORDER BY ipv6.inserted_at DESC, ipv6.address DESC
      LIMIT 1
    ) ipv6 ON TRUE
    """)

    execute("ALTER TABLE client_sessions DROP CONSTRAINT client_sessions_client_id_fkey")
    rename(table(:client_sessions), :client_id, to: :device_id)

    execute(
      "ALTER INDEX client_sessions_account_id_client_id_inserted_at_index RENAME TO client_sessions_account_id_device_id_inserted_at_index"
    )

    execute("""
    ALTER TABLE client_sessions
    ADD CONSTRAINT client_sessions_device_id_fkey
    FOREIGN KEY (account_id, device_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE gateway_sessions DROP CONSTRAINT gateway_sessions_gateway_id_fkey")
    rename(table(:gateway_sessions), :gateway_id, to: :device_id)

    execute(
      "ALTER INDEX gateway_sessions_account_id_gateway_id_inserted_at_index RENAME TO gateway_sessions_account_id_device_id_inserted_at_index"
    )

    execute("""
    ALTER TABLE gateway_sessions
    ADD CONSTRAINT gateway_sessions_device_id_fkey
    FOREIGN KEY (account_id, device_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute(
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_client_id_fkey"
    )

    execute(
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_gateway_id_fkey"
    )

    execute("""
    ALTER TABLE policy_authorizations
    DROP CONSTRAINT IF EXISTS policy_authorizations_receiving_client_id_fkey
    """)

    execute("""
    ALTER TABLE policy_authorizations
    DROP CONSTRAINT IF EXISTS policy_authorizations_gateway_or_receiving_client_required
    """)

    execute("DROP INDEX IF EXISTS policy_authorizations_receiving_client_id_index")

    execute("""
    UPDATE policy_authorizations
    SET gateway_id = COALESCE(receiving_client_id, gateway_id)
    WHERE receiving_client_id IS NOT NULL
    """)

    rename(table(:policy_authorizations), :client_id, to: :initiating_device_id)
    rename(table(:policy_authorizations), :gateway_id, to: :receiving_device_id)

    alter table(:policy_authorizations) do
      remove(:receiving_client_id)
    end

    execute("""
    ALTER TABLE policy_authorizations
    ALTER COLUMN receiving_device_id SET NOT NULL
    """)

    execute("""
    ALTER INDEX IF EXISTS policy_authorizations_gateway_id_index
    RENAME TO policy_authorizations_receiving_device_id_index
    """)

    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_initiating_device_id_fkey
    FOREIGN KEY (account_id, initiating_device_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_receiving_device_id_fkey
    FOREIGN KEY (account_id, receiving_device_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute(
      "ALTER TABLE static_device_pool_members DROP CONSTRAINT static_device_pool_members_client_id_fkey"
    )

    rename(table(:static_device_pool_members), :client_id, to: :device_id)

    alter table(:static_device_pool_members) do
      add(:device_type, :string, null: false, default: "client")
    end

    execute("""
    ALTER INDEX IF EXISTS static_device_pool_members_client_id_index
    RENAME TO static_device_pool_members_device_id_index
    """)

    execute("""
    ALTER INDEX IF EXISTS static_device_pool_members_account_id_resource_id_client_id_index
    RENAME TO static_device_pool_members_account_id_resource_id_device_id_index
    """)

    create(
      constraint(:static_device_pool_members, :static_device_pool_members_device_type_client_only,
        check: "device_type = 'client'"
      )
    )

    execute("""
    ALTER TABLE static_device_pool_members
    ADD CONSTRAINT static_device_pool_members_device_id_device_type_fkey
    FOREIGN KEY (account_id, device_id, device_type)
    REFERENCES devices(account_id, id, type)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE ipv4_addresses DROP CONSTRAINT ipv4_addresses_client_id_fkey")
    execute("ALTER TABLE ipv4_addresses DROP CONSTRAINT ipv4_addresses_gateway_id_fkey")

    execute("""
    ALTER TABLE ipv4_addresses
    ADD CONSTRAINT ipv4_addresses_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE ipv4_addresses
    ADD CONSTRAINT ipv4_addresses_gateway_id_fkey
    FOREIGN KEY (account_id, gateway_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE ipv6_addresses DROP CONSTRAINT ipv6_addresses_client_id_fkey")
    execute("ALTER TABLE ipv6_addresses DROP CONSTRAINT ipv6_addresses_gateway_id_fkey")

    execute("""
    ALTER TABLE ipv6_addresses
    ADD CONSTRAINT ipv6_addresses_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE ipv6_addresses
    ADD CONSTRAINT ipv6_addresses_gateway_id_fkey
    FOREIGN KEY (account_id, gateway_id)
    REFERENCES devices(account_id, id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS assign_device_network_addresses ON devices")
    execute("DROP FUNCTION IF EXISTS assign_device_network_addresses()")
    execute("DROP FUNCTION IF EXISTS find_available_device_address(uuid, text, cidr)")

    execute("ALTER TABLE client_sessions DROP CONSTRAINT client_sessions_device_id_fkey")

    execute(
      "ALTER INDEX client_sessions_account_id_device_id_inserted_at_index RENAME TO client_sessions_account_id_client_id_inserted_at_index"
    )

    rename(table(:client_sessions), :device_id, to: :client_id)

    execute("""
    ALTER TABLE client_sessions
    ADD CONSTRAINT client_sessions_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES clients(account_id, id)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE gateway_sessions DROP CONSTRAINT gateway_sessions_device_id_fkey")

    execute(
      "ALTER INDEX gateway_sessions_account_id_device_id_inserted_at_index RENAME TO gateway_sessions_account_id_gateway_id_inserted_at_index"
    )

    rename(table(:gateway_sessions), :device_id, to: :gateway_id)

    execute("""
    ALTER TABLE gateway_sessions
    ADD CONSTRAINT gateway_sessions_gateway_id_fkey
    FOREIGN KEY (account_id, gateway_id)
    REFERENCES gateways(account_id, id)
    ON DELETE CASCADE
    """)

    execute(
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_initiating_device_id_fkey"
    )

    execute(
      "ALTER TABLE policy_authorizations DROP CONSTRAINT policy_authorizations_receiving_device_id_fkey"
    )

    execute("ALTER TABLE policy_authorizations ADD COLUMN receiving_client_id uuid")

    rename(table(:policy_authorizations), :initiating_device_id, to: :client_id)
    rename(table(:policy_authorizations), :receiving_device_id, to: :gateway_id)

    execute("""
    ALTER TABLE policy_authorizations
    ALTER COLUMN gateway_id DROP NOT NULL
    """)

    execute("""
    UPDATE policy_authorizations pa
    SET receiving_client_id = pa.gateway_id,
        gateway_id = NULL
    FROM devices d
    WHERE pa.account_id = d.account_id
      AND pa.gateway_id = d.id
      AND d.type = 'client'
    """)

    execute("""
    ALTER INDEX IF EXISTS policy_authorizations_receiving_device_id_index
    RENAME TO policy_authorizations_gateway_id_index
    """)

    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES clients(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_gateway_id_fkey
    FOREIGN KEY (account_id, gateway_id)
    REFERENCES gateways(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_receiving_client_id_fkey
    FOREIGN KEY (account_id, receiving_client_id)
    REFERENCES clients(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE policy_authorizations
    ADD CONSTRAINT policy_authorizations_gateway_or_receiving_client_required
    CHECK (gateway_id IS NOT NULL OR receiving_client_id IS NOT NULL)
    """)

    execute("""
    CREATE INDEX policy_authorizations_receiving_client_id_index
    ON policy_authorizations (receiving_client_id)
    WHERE receiving_client_id IS NOT NULL
    """)

    execute(
      "ALTER TABLE static_device_pool_members DROP CONSTRAINT static_device_pool_members_device_id_device_type_fkey"
    )

    drop(
      constraint(:static_device_pool_members, :static_device_pool_members_device_type_client_only)
    )

    execute("""
    ALTER INDEX IF EXISTS static_device_pool_members_device_id_index
    RENAME TO static_device_pool_members_client_id_index
    """)

    execute("""
    ALTER INDEX IF EXISTS static_device_pool_members_account_id_resource_id_device_id_index
    RENAME TO static_device_pool_members_account_id_resource_id_client_id_index
    """)

    alter table(:static_device_pool_members) do
      remove(:device_type)
    end

    rename(table(:static_device_pool_members), :device_id, to: :client_id)

    execute("""
    ALTER TABLE static_device_pool_members
    ADD CONSTRAINT static_device_pool_members_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES clients(account_id, id)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE ipv4_addresses DROP CONSTRAINT ipv4_addresses_client_id_fkey")
    execute("ALTER TABLE ipv4_addresses DROP CONSTRAINT ipv4_addresses_gateway_id_fkey")

    execute("""
    ALTER TABLE ipv4_addresses
    ADD CONSTRAINT ipv4_addresses_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES clients(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE ipv4_addresses
    ADD CONSTRAINT ipv4_addresses_gateway_id_fkey
    FOREIGN KEY (account_id, gateway_id)
    REFERENCES gateways(account_id, id)
    ON DELETE CASCADE
    """)

    execute("ALTER TABLE ipv6_addresses DROP CONSTRAINT ipv6_addresses_client_id_fkey")
    execute("ALTER TABLE ipv6_addresses DROP CONSTRAINT ipv6_addresses_gateway_id_fkey")

    execute("""
    ALTER TABLE ipv6_addresses
    ADD CONSTRAINT ipv6_addresses_client_id_fkey
    FOREIGN KEY (account_id, client_id)
    REFERENCES clients(account_id, id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE ipv6_addresses
    ADD CONSTRAINT ipv6_addresses_gateway_id_fkey
    FOREIGN KEY (account_id, gateway_id)
    REFERENCES gateways(account_id, id)
    ON DELETE CASCADE
    """)

    drop(table(:devices))
  end
end
