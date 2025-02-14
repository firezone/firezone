defmodule Domain.Repo.Migrations.CreateInternetSite do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO gateway_groups (
      id,
      account_id,
      name,
      created_by,
      managed_by,
      inserted_at,
      updated_at
    )
    SELECT
      uuid_generate_v4(),
      id,
      'Internet',
      'system',
      'system',
      NOW(),
      NOW()
    FROM accounts
    WHERE deleted_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM gateway_groups g
      WHERE g.account_id = a.id
        AND g.name = 'Internet'
        AND g.created_by = 'system'
        AND g.managed_by = 'system')
    """)
  end

  def down do
    execute("""
    DELETE FROM gateway_groups
    WHERE name = 'Internet'
      AND created_by = 'system'
      AND managed_by = 'system'
      AND account_id IN (SELECT id FROM accounts WHERE deleted_at IS NULL);
    """)
  end
end
