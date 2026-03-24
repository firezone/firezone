defmodule Portal.Repo.Migrations.CreateFlowLogs do
  use Ecto.Migration

  def change do
    create table(:flow_logs, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:flow_id, :binary_id, primary_key: true, null: false)
      add(:device_id, :binary_id, primary_key: true, null: false)
      add(:role, :string, null: false)
      add(:flow_start, :utc_datetime_usec, null: false)
      add(:flow_end, :utc_datetime_usec, null: false)
      add(:payload, :map, null: false, default: %{})

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(
      constraint(:flow_logs, :flow_logs_role_chk, check: "role IN ('initiator', 'responder')")
    )

    create(constraint(:flow_logs, :flow_end_after_start, check: "flow_end >= flow_start"))
    create(constraint(:flow_logs, :flow_start_in_past, check: "flow_start <= now()"))
    create(constraint(:flow_logs, :flow_end_in_past, check: "flow_end <= now()"))

    create(index(:flow_logs, [:account_id, :flow_start]))
    create(index(:flow_logs, [:account_id, :flow_end]))
  end
end
