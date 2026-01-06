defmodule Portal.Repo.Migrations.RemoveDeletedAtFromRelays do
  use Ecto.Migration

  def change do
    alter table(:relays) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
