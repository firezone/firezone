defmodule Portal.Repo.Migrations.AddMetricsExportToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :metrics_export, :jsonb, null: false, default: fragment(~s('"off"'::jsonb))
    end
  end
end
