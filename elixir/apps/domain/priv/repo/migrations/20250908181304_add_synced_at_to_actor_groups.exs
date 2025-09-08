defmodule Domain.Repo.Migrations.AddSyncedAtToActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:synced_at, :utc_datetime_usec)
    end
  end
end
