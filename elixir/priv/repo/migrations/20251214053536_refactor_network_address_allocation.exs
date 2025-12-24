defmodule Portal.Repo.Migrations.RefactorNetworkAddressAllocation do
  use Ecto.Migration

  def up do
    # Create the PL/pgSQL function for atomic address allocation
    #
    # This function:
    # 1. Finds max(address) for the account, or starts at base + 1
    # 2. Wraps around to offset 1 if we exceed max_offset
    # 3. Tries to insert into ipv4_addresses or ipv6_addresses based on type
    # 4. On collision, continues to next offset
    # 5. Raises exception if we've tried all possible addresses (wrap detection)
    execute("""
    CREATE OR REPLACE FUNCTION allocate_address(
      p_account_id uuid,
      p_type text,
      p_cidr cidr,
      p_client_id uuid DEFAULT NULL,
      p_gateway_id uuid DEFAULT NULL
    ) RETURNS TABLE(account_id uuid, address inet, client_id uuid, gateway_id uuid, inserted_at timestamptz)
    LANGUAGE plpgsql
    AS $$
    DECLARE
      v_base_address inet;
      v_max_address inet;
      v_current_max inet;
      v_next_address inet;
      v_max_offset bigint;
      v_total_addresses bigint;
      v_attempts bigint := 0;
    BEGIN
      v_base_address := host(p_cidr)::inet;
      v_max_address := host(broadcast(p_cidr))::inet - 1;
      v_max_offset := (v_max_address - v_base_address)::bigint;
      v_total_addresses := v_max_offset;

      -- Find the current max address for this account
      IF p_type = 'ipv4' THEN
        SELECT MAX(a.address) INTO v_current_max
        FROM ipv4_addresses a
        WHERE a.account_id = p_account_id;
      ELSIF p_type = 'ipv6' THEN
        SELECT MAX(a.address) INTO v_current_max
        FROM ipv6_addresses a
        WHERE a.account_id = p_account_id;
      ELSE
        RAISE EXCEPTION 'Invalid address type: %. Must be ipv4 or ipv6', p_type
          USING ERRCODE = 'P0001';
      END IF;

      -- Start from max + 1, or base + 1 if no addresses exist
      IF v_current_max IS NULL THEN
        v_next_address := v_base_address + 1;
      ELSE
        v_next_address := v_current_max + 1;
        -- Wrap around if we've exceeded the max
        IF v_next_address > v_max_address THEN
          v_next_address := v_base_address + 1;
        END IF;
      END IF;

      LOOP
        v_attempts := v_attempts + 1;

        IF v_attempts > v_total_addresses THEN
          RAISE EXCEPTION 'Address pool exhausted for account %', p_account_id
            USING ERRCODE = '53400';
        END IF;

        BEGIN
          IF p_type = 'ipv4' THEN
            RETURN QUERY
            INSERT INTO ipv4_addresses (account_id, address, client_id, gateway_id, inserted_at)
            VALUES (p_account_id, v_next_address, p_client_id, p_gateway_id, NOW())
            RETURNING ipv4_addresses.account_id, ipv4_addresses.address, ipv4_addresses.client_id, ipv4_addresses.gateway_id, ipv4_addresses.inserted_at;
            RETURN;
          ELSIF p_type = 'ipv6' THEN
            RETURN QUERY
            INSERT INTO ipv6_addresses (account_id, address, client_id, gateway_id, inserted_at)
            VALUES (p_account_id, v_next_address, p_client_id, p_gateway_id, NOW())
            RETURNING ipv6_addresses.account_id, ipv6_addresses.address, ipv6_addresses.client_id, ipv6_addresses.gateway_id, ipv6_addresses.inserted_at;
            RETURN;
          END IF;
        EXCEPTION WHEN unique_violation THEN
          -- Move to next address, wrapping if needed
          v_next_address := v_next_address + 1;
          IF v_next_address > v_max_address THEN
            v_next_address := v_base_address + 1;
          END IF;
          CONTINUE;
        END;
      END LOOP;
    END;
    $$
    """)

    # Drop redundant unique indexes on clients
    drop_if_exists(index(:clients, [:account_id, :ipv4], name: :clients_account_id_ipv4_index))
    drop_if_exists(index(:clients, [:account_id, :ipv6], name: :clients_account_id_ipv6_index))

    # Drop redundant unique indexes on gateways
    drop_if_exists(index(:gateways, [:account_id, :ipv4], name: :gateways_account_id_ipv4_index))
    drop_if_exists(index(:gateways, [:account_id, :ipv6], name: :gateways_account_id_ipv6_index))
  end

  def down do
    # Recreate unique indexes on clients
    create(unique_index(:clients, [:account_id, :ipv4], name: :clients_account_id_ipv4_index))
    create(unique_index(:clients, [:account_id, :ipv6], name: :clients_account_id_ipv6_index))

    # Recreate unique indexes on gateways
    create(unique_index(:gateways, [:account_id, :ipv4], name: :gateways_account_id_ipv4_index))
    create(unique_index(:gateways, [:account_id, :ipv6], name: :gateways_account_id_ipv6_index))

    # Drop the function
    execute("DROP FUNCTION IF EXISTS allocate_address(uuid, text, cidr, uuid, uuid)")
  end
end
