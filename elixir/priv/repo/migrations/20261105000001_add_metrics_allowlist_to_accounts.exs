defmodule Portal.Repo.Migrations.AddMetricsAllowlistToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :metrics_allowlist, {:array, :text}
    end
  end
end
