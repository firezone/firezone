defmodule Portal.Repo.Migrations.CreatePlanAndAccountMetrics do
  use Ecto.Migration

  def up do
    create table(:plan_metrics, primary_key: false) do
      add :plan, :text, primary_key: true
      add :patterns, {:array, :text}, null: false

      timestamps()
    end

    create table(:account_metrics, primary_key: false) do
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :patterns, {:array, :text}, null: false

      timestamps()
    end
  end

  def down do
    drop table(:account_metrics)
    drop table(:plan_metrics)
  end
end
