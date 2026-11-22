defmodule Portal.Repo.Migrations.AddLastSeenDeviceV1ToDevices do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:last_seen_device_v1, :boolean, null: false, default: false)
    end
  end

  def down do
    alter table(:devices) do
      remove_if_exists(:last_seen_device_v1, :boolean)
    end
  end
end
