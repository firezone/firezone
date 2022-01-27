defmodule FzHttp.Repo.Migrations.AddPersistentKeepalives do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add :persistent_keepalives, :integer
      add :use_default_persistent_keepalives, :boolean, null: false, default: true
    end

    now = DateTime.utc_now()

    execute(
      """
      INSERT INTO settings (key, value, inserted_at, updated_at) VALUES \
      ('default.device.persistent_keepalives', null, '#{now}', '#{now}')
      """,
      """
      DELETE FROM settings WHERE key = 'default.device.persistent_keepalives'
      """
    )
  end
end
