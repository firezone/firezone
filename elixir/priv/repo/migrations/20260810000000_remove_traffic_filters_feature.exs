defmodule Portal.Repo.Migrations.RemoveTrafficFiltersFeature do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET features = features - 'traffic_filters'
    WHERE features ? 'traffic_filters'
    """)
  end

  # The previous per-account values are not recoverable. On rollback, keep all
  # accounts entitled to traffic filters instead of disabling them by default.
  def down do
    execute("""
    UPDATE accounts
    SET features = features || '{"traffic_filters": true}'::jsonb
    """)
  end
end
