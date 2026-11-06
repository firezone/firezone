defmodule Portal.Repo.Migrations.CreateMetricSets do
  use Ecto.Migration

  def up do
    create table(:plan_metric_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plan, :text, null: false
      add :patterns, {:array, :text}, null: false
      add :description, :text

      timestamps()
    end

    create table(:account_metric_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), null: false
      add :patterns, {:array, :text}, null: false
      add :description, :text

      timestamps()
    end

    create_if_not_exists index(:account_metric_sets, [:account_id])
  end

  def down do
    drop_if_exists index(:account_metric_sets, [:account_id])
    drop table(:account_metric_sets)
    drop table(:plan_metric_sets)
  end
end
