defmodule Portal.Repo.Migrations.DeleteConnectionsForDeletedResources do
  use Ecto.Migration

  def change do
    execute("""
    DELETE FROM resource_connections
    WHERE resource_id IN (SELECT id FROM resources WHERE deleted_at IS NOT NULL)
    """)

    execute("""
    DELETE FROM resource_connections
    WHERE gateway_group_id IN (SELECT id FROM gateway_groups WHERE deleted_at IS NOT NULL)
    """)
  end
end
