defmodule Domain.Repo.Migrations.UpdateClientAuthIdentityFkConstraint do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_identity_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_identity_id_fkey
    FOREIGN KEY (identity_id)
    REFERENCES auth_identities(id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_actor_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES actors(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_identity_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_identity_id_fkey
    FOREIGN KEY (identity_id)
    REFERENCES auth_identities(id)
    ON DELETE NO ACTION
    """)

    execute("""
    ALTER TABLE clients
    DROP CONSTRAINT IF EXISTS devices_actor_id_fkey
    """)

    execute("""
    ALTER TABLE clients
    ADD CONSTRAINT devices_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES actors(id)
    ON DELETE NO ACTION
    """)
  end
end
