defmodule Portal.Repo.Migrations.ConnectInternetResourceToInternetSite do
  use Ecto.Migration

  def change do
    execute("""
    INSERT INTO resource_connections (account_id, resource_id, gateway_group_id, created_by)
    SELECT
      a.id AS account_id,
      r.id AS resource_id,
      gg.id AS gateway_group_id,
      'system' AS created_by
    FROM accounts a
    JOIN resources r ON r.account_id = a.id
    JOIN gateway_groups gg ON gg.account_id = a.id
    WHERE
      a.deleted_at IS NULL
      AND r.type = 'internet'
      AND gg.managed_by = 'system'
      AND gg.name = 'Internet'
      AND NOT EXISTS (
        SELECT 1
        FROM resource_connections rc
        WHERE rc.account_id = a.id
          AND rc.resource_id = r.id
      )
    """)
  end
end
