defmodule Portal.Repo.Migrations.AddGroupSyncModeToGoogleDirectories do
  use Ecto.Migration

  def change do
    alter table(:google_directories) do
      add(:group_sync_mode, :string, null: false, default: "all")
      add(:orgunit_sync_enabled, :boolean, null: false, default: false)
    end

    execute("UPDATE google_directories SET orgunit_sync_enabled = TRUE")

    create(
      constraint(:google_directories, :group_sync_mode_values,
        check: "group_sync_mode IN ('all', 'filtered', 'disabled')"
      )
    )
  end
end
