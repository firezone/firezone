defmodule FzHttp.Repo.Migrations.AddMtuToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:use_default_mtu, :boolean, default: true, null: false)
      add(:mtu, :integer, default: nil)
    end

    now = DateTime.utc_now()

    execute(
      """
      INSERT INTO settings (key, value, inserted_at, updated_at) VALUES \
      ('default.device.mtu', null, '#{now}', '#{now}')
      """,
      """
      DELETE FROM settings WHERE key = 'default.device.mtu'
      """
    )
  end
end
