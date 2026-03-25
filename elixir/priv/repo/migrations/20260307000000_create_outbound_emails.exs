defmodule Portal.Repo.Migrations.CreateOutboundEmails do
  use Ecto.Migration

  def change do
    create table(:outbound_emails, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:message_id, :text, null: false, primary_key: true)
      add(:subject, :text, null: false)
      add(:recipients, {:array, :text}, null: false, default: [])

      timestamps(type: :utc_datetime_usec)
    end

    create table(:email_suppressions, primary_key: false) do
      add(:email, :text, primary_key: true, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # message_id is listed first so the PK index (message_id, account_id, email)
    # supports efficient lookups by message_id + email in ACS webhook processing.
    create table(:outbound_email_deliveries, primary_key: false) do
      add(
        :message_id,
        references(:outbound_emails,
          column: :message_id,
          type: :text,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false,
        primary_key: true
      )

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:email, :text, null: false, primary_key: true)
      add(:status, :string, null: false)
      add(:failure_code, :text)
      add(:failure_message, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:outbound_emails, [:inserted_at]))
  end
end
