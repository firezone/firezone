defmodule Portal.Repo.Migrations.DropClientTokens do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")
    drop_if_exists(table(:client_tokens))
  end

  def down do
    raise Ecto.MigrationError, "client_tokens cannot be restored; its rows live in device_tokens"
  end
end
