defmodule Portal.Repo.Migrations.DropLastSeenDeviceV1FromDevices do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      remove_if_exists(:last_seen_device_v1, :boolean)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:last_seen_device_v1, :boolean, null: false, default: false)
    end
  end
end
