defmodule Portal.Repo.Migrations.DropPlanAndAccountMetrics do
  @moduledoc """
  Manual on purpose: run only after the release that reads `metrics_rules`
  instead is fully rolled out, since old nodes still read these tables.
  """
  use Ecto.Migration

  def up do
    drop_if_exists table(:account_metrics)
    drop_if_exists table(:plan_metrics)
  end

  def down do
    create_if_not_exists table(:plan_metrics, primary_key: false) do
      add :plan, :text, primary_key: true
      add :patterns, {:array, :text}, null: false

      timestamps()
    end

    create_if_not_exists table(:account_metrics, primary_key: false) do
      add :account_id, references(:accounts, type: :uuid, on_delete: :delete_all), primary_key: true
      add :patterns, {:array, :text}, null: false

      timestamps()
    end
  end
end
