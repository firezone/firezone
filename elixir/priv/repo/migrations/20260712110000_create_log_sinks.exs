defmodule Portal.Repo.Migrations.CreateLogSinks do
  use Ecto.Migration

  def change do
    create table(:log_sinks, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:type, :string, null: false)
    end

    create(constraint(:log_sinks, :type_must_be_valid, check: "type IN ('splunk')"))

    create table(:splunk_log_sinks, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :id,
        references(:log_sinks,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:name, :string, null: false)
      add(:collector_url, :text, null: false)
      add(:hec_token, :string, null: false)
      add(:index, :string)
      add(:enabled_streams, {:array, :string}, null: false)
      add(:retroactive, :boolean, default: false, null: false)

      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      add(:last_error_email_at, :timestamptz)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)

      timestamps()
    end

    create(unique_index(:splunk_log_sinks, [:account_id, :name]))

    create table(:log_sink_cursors, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :log_sink_id,
        references(:log_sinks,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:stream, :string, null: false, primary_key: true)
      add(:phase, :string, null: false, primary_key: true)

      add(:cursor, :bigint, null: false, default: 0)
      add(:until_seq, :bigint)
      add(:synced_count, :bigint, null: false, default: 0)
      add(:dropped_count, :bigint, null: false, default: 0)
      add(:backfill_total, :bigint)
      add(:completed_at, :timestamptz)
      add(:last_synced_at, :timestamptz)

      timestamps()
    end

    create(
      constraint(:log_sink_cursors, :stream_must_be_valid,
        check: "stream IN ('change', 'session', 'api_request', 'flow')"
      )
    )

    create(
      constraint(:log_sink_cursors, :phase_must_be_valid,
        check: "phase IN ('live', 'backfill')"
      )
    )
  end
end
