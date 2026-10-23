defmodule Portal.Repo.Migrations.CreateDeviceActors do
  @moduledoc """
  A device is a machine; the people who sign in on it are recorded here, one
  row per device and actor, rather than as a single owner column on the
  device. Rows are created on connect and carry the first and latest time the
  actor was seen on that device.

  Deleting the device or the actor removes the rows.
  """
  use Ecto.Migration

  def change do
    create table(:device_actors, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:device_id, :binary_id, null: false, primary_key: true)
      add(:actor_id, :binary_id, null: false, primary_key: true)

      add(:first_seen_at, :timestamptz, null: false)
      add(:last_seen_at, :timestamptz, null: false)
    end

    execute(
      """
      ALTER TABLE device_actors
      ADD CONSTRAINT device_actors_device_id_fkey
      FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE device_actors DROP CONSTRAINT device_actors_device_id_fkey"
    )

    execute(
      """
      ALTER TABLE device_actors
      ADD CONSTRAINT device_actors_actor_id_fkey
      FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE device_actors DROP CONSTRAINT device_actors_actor_id_fkey"
    )

    # The primary key already covers lookups by device; this covers the
    # actor's devices (own-devices pools, the actor page, seats).
    create(index(:device_actors, [:account_id, :actor_id]))
  end
end
