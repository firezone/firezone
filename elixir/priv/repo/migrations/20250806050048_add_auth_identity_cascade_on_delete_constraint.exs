defmodule Portal.Repo.Migrations.AddAuthIdentityCascadeOnDeleteConstraint do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE auth_identities
    DROP CONSTRAINT IF EXISTS auth_identities_provider_id_fkey
    """)

    execute("""
    ALTER TABLE auth_identities
    DROP CONSTRAINT IF EXISTS auth_identities_actor_id_fkey
    """)

    execute("""
    ALTER TABLE auth_identities
    ADD CONSTRAINT auth_identities_provider_id_fkey
    FOREIGN KEY (provider_id)
    REFERENCES auth_providers(id)
    ON DELETE CASCADE
    """)

    execute("""
    ALTER TABLE auth_identities
    ADD CONSTRAINT auth_identities_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES actors(id)
    ON DELETE CASCADE
    """)
  end

  def down do
    execute("""
    ALTER TABLE auth_identities
    DROP CONSTRAINT IF EXISTS auth_identities_provider_id_fkey
    """)

    execute("""
    ALTER TABLE auth_identities
    DROP CONSTRAINT IF EXISTS auth_identities_actor_id_fkey
    """)

    execute("""
    ALTER TABLE auth_identities
    ADD CONSTRAINT auth_identities_provider_id_fkey
    FOREIGN KEY (provider_id)
    REFERENCES auth_providers(id)
    ON DELETE NO ACTION
    """)

    execute("""
    ALTER TABLE auth_identities
    ADD CONSTRAINT auth_identities_actor_id_fkey
    FOREIGN KEY (actor_id)
    REFERENCES actors(id)
    ON DELETE NO ACTION
    """)
  end
end
