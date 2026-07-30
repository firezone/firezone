defmodule Portal.Repo.Migrations.AddSyncAllDomainsToGoogleDirectories do
  use Ecto.Migration

  def change do
    alter table(:google_directories) do
      add(:sync_all_domains, :boolean, null: false, default: false)
    end
  end
end
