defmodule Portal.Repo.Migrations.AddDevicesKeyColumns do
  use Ecto.Migration

  # The foreign key is added NOT VALID and validated in a later migration.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:key_hash, :binary)
      add_if_not_exists(:ephemeral, :boolean, null: false, default: false)
      add_if_not_exists(:enrolled_by_actor_id, :binary_id)
      add_if_not_exists(:enrolled_at, :utc_datetime_usec)
    end

    execute("""
    ALTER TABLE devices
      DROP CONSTRAINT IF EXISTS devices_enrolled_by_actor_id_fkey,
      ADD CONSTRAINT devices_enrolled_by_actor_id_fkey
        FOREIGN KEY (account_id, enrolled_by_actor_id)
        REFERENCES actors (account_id, id)
        ON DELETE SET NULL (enrolled_by_actor_id)
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      remove_if_exists(:enrolled_at, :utc_datetime_usec)
      remove_if_exists(:enrolled_by_actor_id, :binary_id)
      remove_if_exists(:ephemeral, :boolean)
      remove_if_exists(:key_hash, :binary)
    end
  end
end
