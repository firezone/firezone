defmodule Portal.Repo.Migrations.KeepDevicesWhenActorDeleted do
  use Ecto.Migration

  # A device is a machine, not a user's possession, so deleting a user only
  # clears the device's actor. Its other users stay in device_actors.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")
    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS device_type_client_fields")
    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_actor_id_fkey")

    execute("""
    ALTER TABLE devices
      ADD CONSTRAINT devices_actor_id_fkey
        FOREIGN KEY (account_id, actor_id)
        REFERENCES actors (account_id, id)
        ON DELETE SET NULL (actor_id)
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")
    execute("ALTER TABLE devices DROP CONSTRAINT IF EXISTS devices_actor_id_fkey")

    execute("""
    ALTER TABLE devices
      ADD CONSTRAINT devices_actor_id_fkey
        FOREIGN KEY (account_id, actor_id)
        REFERENCES actors (account_id, id)
        ON DELETE CASCADE
        NOT VALID
    """)
  end
end
