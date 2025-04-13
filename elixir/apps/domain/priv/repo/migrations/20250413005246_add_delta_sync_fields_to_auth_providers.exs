defmodule Domain.Repo.Migrations.AddDeltaSyncFieldsToAuthProviders do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:user_delta_sync_started_at, :utc_datetime_usec)
      add(:user_delta_sync_finished_at, :utc_datetime_usec)
      add(:user_full_sync_started_at, :utc_datetime_usec)
      add(:user_full_sync_finished_at, :utc_datetime_usec)

      add(:group_delta_sync_started_at, :utc_datetime_usec)
      add(:group_delta_sync_finished_at, :utc_datetime_usec)
      add(:group_full_sync_started_at, :utc_datetime_usec)
      add(:group_full_sync_finished_at, :utc_datetime_usec)

      add(:member_delta_sync_started_at, :utc_datetime_usec)
      add(:member_delta_sync_finished_at, :utc_datetime_usec)
      add(:member_full_sync_started_at, :utc_datetime_usec)
      add(:member_full_sync_finished_at, :utc_datetime_usec)
    end

    execute("""
      UPDATE auth_providers
      SET user_full_sync_finished_at = last_synced_at,
          group_full_sync_finished_at = last_synced_at,
          member_full_sync_finished_at = last_synced_at
    """)

    alter table(:auth_providers) do
      remove(:last_synced_at)
    end
  end
end
