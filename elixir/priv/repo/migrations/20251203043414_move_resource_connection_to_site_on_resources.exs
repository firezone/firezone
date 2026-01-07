defmodule Portal.Repo.Migrations.MoveResourceConnectionToSiteOnResources do
  use Ecto.Migration

  def change do
    # Add site_id column to resources table
    alter table(:resources) do
      add(:site_id, :binary_id)
    end

    # Create unique constraint on sites table for composite key
    create(unique_index(:sites, [:account_id, :id]))

    # Create index for the composite foreign key
    create(index(:resources, [:account_id, :site_id]))

    # Create composite foreign key constraint to ensure site belongs to same account
    execute(
      """
        ALTER TABLE resources
        ADD CONSTRAINT resources_account_id_site_id_fkey
        FOREIGN KEY (account_id, site_id)
        REFERENCES sites (account_id, id)
        ON DELETE CASCADE
      """,
      """
        ALTER TABLE resources
        DROP CONSTRAINT resources_account_id_site_id_fkey
      """
    )

    # Migrate data from resource_connections to populate site_id
    execute(
      """
        UPDATE resources
        SET site_id = (
          SELECT site_id
          FROM resource_connections
          WHERE resource_connections.resource_id = resources.id
          LIMIT 1
        )
        WHERE EXISTS (
          SELECT 1
          FROM resource_connections
          WHERE resource_connections.resource_id = resources.id
        )
      """,
      """
        UPDATE resources SET site_id = NULL
      """
    )

    # Drop the resource_connections table
    drop(table(:resource_connections))
  end
end
