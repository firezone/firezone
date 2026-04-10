defmodule Portal.Repo.Migrations.UpgradeObanJobsToV13 do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 13)
  end

  def down do
    Oban.Migration.down(version: 13)
  end
end
