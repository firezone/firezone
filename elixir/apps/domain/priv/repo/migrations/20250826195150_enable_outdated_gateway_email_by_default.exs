defmodule Domain.Repo.Migrations.EnableOutdatedGatewayEmailByDefault do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      COALESCE(config, '{}'::jsonb),
      '{notifications,outdated_gateway,enabled}',
      'true'::jsonb,
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
      COALESCE(config, '{}'::jsonb),
      '{notifications,outdated_gateway,enabled}',
      'false'::jsonb,
      true
    )
    WHERE deleted_at IS NULL
      AND disabled_at IS NULL
    """)
  end
end
