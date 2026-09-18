defmodule Portal.Repo.Migrations.CollapseDevicePoolTypes do
  use Ecto.Migration

  @own_devices ~s({"device": {"field": "actor_id", "op": "eq", "value": {"subject": "actor_id"}}})

  def up do
    execute("ALTER TABLE resources DROP CONSTRAINT resources_device_membership_criteria_matches_type")
    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    UPDATE resources
    SET device_membership_criteria = jsonb_build_object(
      'device', jsonb_build_object(
        'field', 'id',
        'op', 'in',
        'value', COALESCE((
          SELECT jsonb_agg(m.device_id::text ORDER BY m.device_id)
          FROM static_device_pool_members m
          WHERE m.account_id = resources.account_id AND m.resource_id = resources.id
        ), '[]'::jsonb)
      )
    )
    WHERE type = 'static_device_pool'
    """)

    execute("""
    UPDATE resources
    SET type = 'device_pool'
    WHERE type IN ('static_device_pool', 'dynamic_device_pool')
    """)

    create(
      constraint(:resources, :resources_device_membership_criteria_matches_type,
        check: "(type = 'device_pool') = (device_membership_criteria IS NOT NULL)"
      )
    )

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type IN ('internet', 'device_pool') AND address IS NULL)
    );
    """)

    drop(table(:static_device_pool_members))
  end

  def down do
    create table(:static_device_pool_members, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:resource_id,
        references(:resources,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:device_id, :binary_id, null: false)
      add(:device_type, :string, null: false, default: "client")
    end

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

    create_if_not_exists(index(:static_device_pool_members, [:resource_id]))
    create_if_not_exists(index(:static_device_pool_members, [:device_id]))

    create_if_not_exists(
      unique_index(:static_device_pool_members, [:account_id, :resource_id, :device_id],
        name: :static_device_pool_members_account_id_resource_id_device_id_index
      )
    )

    execute("""
    INSERT INTO static_device_pool_members (account_id, resource_id, device_id)
    SELECT r.account_id, r.id, (m.value #>> '{}')::uuid
    FROM resources r
    CROSS JOIN LATERAL jsonb_array_elements(r.device_membership_criteria #> '{device,value}') AS m
    JOIN devices d ON d.account_id = r.account_id AND d.id = (m.value #>> '{}')::uuid AND d.type = 'client'
    WHERE r.type = 'device_pool' AND r.device_membership_criteria #>> '{device,field}' = 'id'
    """)

    execute("ALTER TABLE resources DROP CONSTRAINT resources_device_membership_criteria_matches_type")
    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    UPDATE resources
    SET type = 'static_device_pool', device_membership_criteria = NULL
    WHERE type = 'device_pool' AND device_membership_criteria #>> '{device,field}' = 'id'
    """)

    execute("""
    UPDATE resources
    SET type = 'dynamic_device_pool', device_membership_criteria = '#{@own_devices}'
    WHERE type = 'device_pool'
    """)

    create(
      constraint(:resources, :resources_device_membership_criteria_matches_type,
        check: "(type = 'dynamic_device_pool') = (device_membership_criteria IS NOT NULL)"
      )
    )

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type IN ('internet', 'static_device_pool', 'dynamic_device_pool') AND address IS NULL)
    );
    """)
  end
end
