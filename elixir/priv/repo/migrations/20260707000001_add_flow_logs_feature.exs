defmodule Portal.Repo.Migrations.AddFlowLogsFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('flow_logs', false)",
      "DELETE FROM features WHERE feature = 'flow_logs'"
    )
  end
end
