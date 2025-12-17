defmodule Portal.Repo.Migrations.UpdateRelayFkConstraint do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE relays
    DROP CONSTRAINT IF EXISTS relays_group_id_fkey
    """)

    execute("""
    ALTER TABLE relays
    ADD CONSTRAINT relays_group_id_fkey
    FOREIGN KEY (group_id)
    REFERENCES relay_groups(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE relays
    DROP CONSTRAINT IF EXISTS relays_group_id_fkey
    """)

    execute("""
    ALTER TABLE relays
    ADD CONSTRAINT relays_group_id_fkey
    FOREIGN KEY (group_id)
    REFERENCES relay_groups(id)
    ON DELETE NO ACTION
    """)
  end
end
