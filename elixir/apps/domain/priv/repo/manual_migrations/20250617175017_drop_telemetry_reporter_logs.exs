defmodule Domain.Repo.Migrations.DropTelemetryReporterLogs do
  use Ecto.Migration

  def up do
    drop(table(:telemetry_reporter_logs))
  end

  def down do
    create table(:telemetry_reporter_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:reporter_module, :string, null: false)
      add(:last_flushed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:telemetry_reporter_logs, [:reporter_module], unique: true))
  end
end
