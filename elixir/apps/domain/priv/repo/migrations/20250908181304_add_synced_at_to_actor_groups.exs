defmodule Domain.Repo.Migrations.AddSyncedAtToActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:synced_at, :utc_datetime_usec)
    end

    create(
      index(:actor_groups, [:account_id, :provider_id, :synced_at],
        where: "synced_at IS NOT NULL"
      )
    )
  end
end
