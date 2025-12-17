defmodule Portal.Repo.Migrations.RemoveLastSyncedAtFromActors do
  use Ecto.Migration

  def up do
    alter table(:actors) do
      remove(:last_synced_at)
    end
  end

  def down do
    alter table(:actors) do
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
