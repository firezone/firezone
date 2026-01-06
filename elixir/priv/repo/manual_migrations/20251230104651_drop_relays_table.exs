defmodule Portal.Repo.Migrations.DropRelaysTable do
  use Ecto.Migration

  def change do
    # Relays are now ephemeral and tracked only via Phoenix Presence.
    # The relays table is no longer needed.
    drop(table(:relays))
  end
end
