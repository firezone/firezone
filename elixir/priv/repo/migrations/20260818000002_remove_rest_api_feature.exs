defmodule Portal.Repo.Migrations.RemoveRestApiFeature do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET features = features - 'rest_api'
    WHERE features ? 'rest_api'
    """)

    execute("""
    UPDATE accounts
    SET metadata = metadata - 'rest_api_requested_at'
    WHERE metadata ? 'rest_api_requested_at'
    """)
  end

  # The previous per-account values are not recoverable. On rollback, keep all
  # accounts entitled to the REST API instead of disabling them by default.
  # Beta access request timestamps are dropped for good.
  def down do
    execute("""
    UPDATE accounts
    SET features = features || '{"rest_api": true}'::jsonb
    """)
  end
end
