defmodule Portal.Repo.Migrations.AddDeviceMembershipCriteriaToResources do
  use Ecto.Migration

  @own_devices ~s({"device": {"field": "actor_id", "op": "eq", "value": {"subject": "actor_id"}}})

  def up do
    alter table(:resources) do
      add(:device_membership_criteria, :map)
    end

    execute("""
    UPDATE resources
    SET device_membership_criteria = '#{@own_devices}', address = NULL
    WHERE type = 'dynamic_device_pool'
    """)

    create(
      constraint(:resources, :resources_device_membership_criteria_matches_type,
        check: "(type = 'dynamic_device_pool') = (device_membership_criteria IS NOT NULL)"
      )
    )

    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type IN ('internet', 'static_device_pool', 'dynamic_device_pool') AND address IS NULL)
    );
    """)
  end

  def down do
    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns', 'dynamic_device_pool') AND address IS NOT NULL)
      OR (type IN ('internet', 'static_device_pool') AND address IS NULL)
    );
    """)

    drop(constraint(:resources, :resources_device_membership_criteria_matches_type))

    alter table(:resources) do
      remove(:device_membership_criteria)
    end
  end
end
