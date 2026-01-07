defmodule Portal.Repo.Migrations.DropFlowActivities do
  use Ecto.Migration

  # Flow activities is completely unused at the time of this migration,
  # so we don't expect to ever need to roll back this migration.
  def change do
    drop(table(:flow_activities))
  end
end
