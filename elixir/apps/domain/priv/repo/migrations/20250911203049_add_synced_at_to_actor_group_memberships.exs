defmodule Domain.Repo.Migrations.AddSyncedAtToActorGroupMemberships do
  use Ecto.Migration

  def change do
    alter table(:actor_group_memberships) do
      add(:synced_at, :utc_datetime_usec)
    end

    create(index(:actor_group_memberships, [:synced_at], where: "synced_at IS NOT NULL"))
  end
end
