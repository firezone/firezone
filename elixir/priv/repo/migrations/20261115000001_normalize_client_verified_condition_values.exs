defmodule Portal.Repo.Migrations.NormalizeClientVerifiedConditionValues do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE policies
    SET conditions = ARRAY(
      SELECT
        CASE
          WHEN c ->> 'property' = 'client_verified' THEN jsonb_set(c, '{values}', '["true"]'::jsonb)
          ELSE c
        END
      FROM unnest(conditions) WITH ORDINALITY AS t(c, position)
      ORDER BY position
    )
    WHERE EXISTS (
      SELECT 1
      FROM unnest(conditions) c
      WHERE c ->> 'property' = 'client_verified' AND c -> 'values' IS DISTINCT FROM '["true"]'::jsonb
    )
    """)
  end

  def down do
  end
end
