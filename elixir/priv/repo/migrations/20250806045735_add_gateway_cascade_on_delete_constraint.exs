defmodule Portal.Repo.Migrations.AddGatewayCascadeOnDeleteConstraint do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE gateways
    DROP CONSTRAINT IF EXISTS gateways_group_id_fkey
    """)

    execute("""
    ALTER TABLE gateways
    ADD CONSTRAINT gateways_group_id_fkey
    FOREIGN KEY (group_id)
    REFERENCES gateway_groups(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE gateways
    DROP CONSTRAINT IF EXISTS gateways_group_id_fkey
    """)

    execute("""
    ALTER TABLE gateways
    ADD CONSTRAINT gateways_group_id_fkey
    FOREIGN KEY (group_id)
    REFERENCES gateway_groups(id)
    ON DELETE NO ACTION
    """)
  end
end
