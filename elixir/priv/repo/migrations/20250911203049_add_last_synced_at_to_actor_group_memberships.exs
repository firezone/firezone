defmodule Portal.Repo.Migrations.AddLastSyncedAtToActorGroupMemberships do
  use Ecto.Migration

  def change do
    alter table(:actor_group_memberships) do
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
