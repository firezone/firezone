defmodule Portal.Repo.Migrations.AddSyncAllDomainsToGoogleDirectories do
  use Ecto.Migration

  def change do
    # A false default leaves existing directories syncing only their primary
    # domain, so nobody's user list changes on deploy.
    alter table(:google_directories) do
      add(:sync_all_domains, :boolean, null: false, default: false)
    end

    # Switching the default afterwards only affects rows inserted from here on,
    # so directories created from now on cover every domain in the account.
    # This has to be a second alter/2: within one block Ecto reverses the
    # operations to [remove, modify], which drops the column before modifying it.
    alter table(:google_directories) do
      modify(:sync_all_domains, :boolean,
        null: false,
        default: true,
        from: {:boolean, null: false, default: false}
      )
    end
  end
end
