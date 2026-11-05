defmodule Portal.Repo.Migrations.AddMetricsExportToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :metrics_export, :jsonb
      add :metrics_export_interval_secs, :integer, null: false, default: 60
    end
  end
end
