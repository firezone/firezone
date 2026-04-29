defmodule Portal.Repo.Migrations.AddDynamicDevicePoolResourceType do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns', 'dynamic_device_pool') AND address IS NOT NULL)
      OR (type IN ('internet', 'static_device_pool') AND address IS NULL)
    );
    """)
  end

  def down do
    execute("ALTER TABLE resources DROP CONSTRAINT require_resources_address")

    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT require_resources_address CHECK (
      (type IN ('cidr', 'ip', 'dns') AND address IS NOT NULL)
      OR (type IN ('internet', 'static_device_pool') AND address IS NULL)
    );
    """)
  end
end
