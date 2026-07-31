defmodule Portal.Repo.Migrations.AddSyncAllDomainsToGoogleDirectories do
  use Ecto.Migration

  def change do
    # Existing directories keep syncing only their primary domain.
    alter table(:google_directories) do
      add(:sync_all_domains, :boolean, null: false, default: false)
    end

    # New rows cover every domain. Separate alter/2 because within one block Ecto
    # reverses to [remove, modify], dropping the column before modifying it.
    alter table(:google_directories) do
      modify(:sync_all_domains, :boolean,
        null: false,
        default: true,
        from: {:boolean, null: false, default: false}
      )
    end
  end
end
