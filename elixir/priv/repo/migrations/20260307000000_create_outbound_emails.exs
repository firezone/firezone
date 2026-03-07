defmodule Portal.Repo.Migrations.CreateOutboundEmails do
  use Ecto.Migration

  def change do
    create table(:outbound_emails, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:priority, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:request, :map, null: false)
      add(:response, :map)
      add(:last_attempted_at, :utc_datetime_usec)
      add(:message_id, :text)
      add(:failed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create table(:email_suppressions, primary_key: false) do
      add(:email, :text, primary_key: true, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:outbound_emails, [:id]))

    create table(:outbound_email_recipients, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :outbound_email_id,
        references(:outbound_emails, column: :id, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:email, :text, null: false)
      add(:last_event_at, :utc_datetime_usec)
      add(:failure_code, :text)
      add(:failure_message, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:outbound_emails, [:inserted_at]))
    create(index(:outbound_emails, [:status, :last_attempted_at]))
    create(index(:outbound_emails, [:message_id]))
    create(index(:outbound_email_recipients, [:outbound_email_id]))
    create(index(:outbound_email_recipients, [:account_id]))
    create(index(:outbound_email_recipients, [:email]))
    create(index(:outbound_email_recipients, [:status]))
  end
end
