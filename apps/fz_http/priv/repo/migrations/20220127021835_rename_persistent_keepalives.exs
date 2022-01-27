defmodule FzHttp.Repo.Migrations.RenamePersistentKeepalives do
  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE settings
      SET key = 'default.device.persistent_keepalive'
      WHERE key = 'default.device.persistent_keepalives'
      """,
      """
      UPDATE settings
      SET key = 'default.device.persistent_keepalives'
      WHERE key = 'default.device.persistent_keepalive'
      """
    )

    rename table(:devices), :persistent_keepalives, to: :persistent_keepalive

    rename table(:devices), :use_default_persistent_keepalives,
      to: :use_default_persistent_keepalive
  end
end
