defmodule Portal.Repo.Migrations.RemoveFlowLogsFeature do
  use Ecto.Migration

  def change do
    execute(
      "DELETE FROM features WHERE feature = 'flow_logs'",
      # Restores the flag as enabled: flow logs are on for every account now,
      # so a rollback that reinserted it disabled would turn them all off.
      "INSERT INTO features (feature, enabled) VALUES ('flow_logs', true)"
    )
  end
end
