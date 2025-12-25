defmodule Portal.Repo.Migrations.AddLastSyncedAtToActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
