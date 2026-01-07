defmodule Portal.Repo.Migrations.RemoveFlowActivitiesFeature do
  use Ecto.Migration

  # The flow_activities feature is completely unused at the time of this
  # migration, so we don't support re-adding this JSONB embedded field.
  def change do
    execute("""
      UPDATE accounts
      SET features = features - 'flow_activities'
      WHERE features ? 'flow_activities';
    """)
  end
end
