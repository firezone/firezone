defmodule Portal.Repo.Migrations.EnableOutdatedGatewayEmailByDefault do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      jsonb_set(
        COALESCE(config, '{}'::jsonb),
        '{notifications}',
        CASE
          WHEN config->'notifications' IS NULL OR config->'notifications' = 'null'::jsonb THEN '{}'::jsonb
          ELSE config->'notifications'
        END,
        true
      ),
      '{notifications,outdated_gateway}',
      jsonb_build_object('enabled', true),
      true
    )
    WHERE deleted_at IS NULL
      AND disabled_at IS NULL
    """)
  end

  def down do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      jsonb_set(
        COALESCE(config, '{}'::jsonb),
        '{notifications}',
        CASE
          WHEN config->'notifications' IS NULL OR config->'notifications' = 'null'::jsonb THEN '{}'::jsonb
          ELSE config->'notifications'
        END,
        true
      ),
      '{notifications,outdated_gateway}',
      jsonb_build_object('enabled', false),
      true
    )
    WHERE deleted_at IS NULL
      AND disabled_at IS NULL
    """)
  end
end
