defmodule Portal.Repo.Migrations.CreateTelemetryReporterLogs do
  use Ecto.Migration

  def change do
    create table(:telemetry_reporter_logs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:reporter_module, :string, null: false)
      add(:last_flushed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:telemetry_reporter_logs, [:reporter_module], unique: true))
  end
end
