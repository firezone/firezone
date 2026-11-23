defmodule Portal.Repo.Migrations.CreateMetricsRules do
  use Ecto.Migration

  def up do
    create table(:metrics_rules, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :match, :jsonb, null: false
      add :patterns, {:array, :text}, null: false
      add :label_devices, :boolean, null: false, default: false
      add :export_interval_secs, :integer
      add :expires_at, :timestamptz

      timestamps()
    end

    execute("""
    INSERT INTO metrics_rules (id, match, patterns, inserted_at, updated_at)
    SELECT gen_random_uuid(), jsonb_build_object('plan', plan), patterns, inserted_at, updated_at
    FROM plan_metrics
    """)

    execute("""
    INSERT INTO metrics_rules (id, match, patterns, inserted_at, updated_at)
    SELECT gen_random_uuid(), jsonb_build_object('account_id', account_id::text), patterns, inserted_at, updated_at
    FROM account_metrics
    """)
  end

  def down do
    drop table(:metrics_rules)
  end
end
