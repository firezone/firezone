defmodule Domain.Repo.Migrations.AddSyncedAtToActorGroupMemberships do
  use Ecto.Migration

  def change do
    alter table(:actor_group_memberships) do
      add(:synced_at, :utc_datetime_usec)
    end
  end
end
