defmodule Portal.Repo.Migrations.DropDevicesSiteId do
  use Ecto.Migration

  # A gateway's site lives in site_devices. Dropping the column also drops its
  # foreign key, its indexes and the client check that mentioned it; the check
  # comes back without the column, unvalidated so the table is not scanned
  # under this lock.
  def up do
    drop_if_exists(constraint(:devices, :device_type_client_fields))

    alter table(:devices) do
      remove_if_exists(:site_id)
    end

    execute("""
    ALTER TABLE devices
    ADD CONSTRAINT device_type_client_fields
    CHECK (type != 'client' OR actor_id IS NOT NULL) NOT VALID
    """)
  end

  def down do
    drop_if_exists(constraint(:devices, :device_type_client_fields))

    alter table(:devices) do
      add_if_not_exists(:site_id, :binary_id)
    end

    create(
      constraint(:devices, :device_type_client_fields,
        check: "type != 'client' OR (actor_id IS NOT NULL AND site_id IS NULL)"
      )
    )
  end
end
