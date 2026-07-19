defmodule Portal.Repo.Migrations.CreateHttpLogSinks do
  use Ecto.Migration

  def up do
    drop(constraint(:log_sinks, :type_must_be_valid))

    create(
      constraint(:log_sinks, :type_must_be_valid,
        check: "type IN ('splunk', 'datadog', 'newrelic', 'elastic', 'sentinel', 's3', 'qradar', 'http')"
      )
    )

    create table(:http_log_sinks, primary_key: false) do
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
      add(:endpoint_url, :text, null: false)
      add(:bearer_token, :text)
      add(:batch_max_events, :integer, default: 100, null: false)
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

    create(unique_index(:http_log_sinks, [:account_id, :name]))
  end

  def down do
    drop(table(:http_log_sinks))
    drop(constraint(:log_sinks, :type_must_be_valid))

    create(
      constraint(:log_sinks, :type_must_be_valid,
        check: "type IN ('splunk', 'datadog', 'newrelic', 'elastic', 'sentinel', 's3', 'qradar')"
      )
    )
  end
end
