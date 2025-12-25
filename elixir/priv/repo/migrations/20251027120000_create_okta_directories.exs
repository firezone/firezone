defmodule Portal.Repo.Migrations.CreateOktaDirectories do
  use Ecto.Migration

  def change do
    create table(:okta_directories, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:client_id, :string)
      add(:private_key_jwk, :jsonb)
      add(:kid, :string)
      add(:okta_domain, :string, null: false)

      add(:name, :string, null: false)
      add(:errored_at, :utc_datetime_usec)
      add(:synced_at, :utc_datetime_usec)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      add(:is_verified, :boolean, default: false, null: false)

      add(:created_by, :string, null: false)
      add(:created_by_subject, :map)
      timestamps()
    end

    create(
      index(:okta_directories, [:account_id, :okta_domain],
        name: :okta_directories_account_id_okta_domain_index,
        unique: true
      )
    )

    create(
      index(:okta_directories, [:account_id, :name],
        name: :okta_directories_account_id_name_index,
        unique: true
      )
    )

    execute(
      """
      ALTER TABLE okta_directories
      ADD CONSTRAINT okta_directories_directory_id_fkey
      FOREIGN KEY (account_id, id)
      REFERENCES directories(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE okta_directories
      DROP CONSTRAINT okta_directories_directory_id_fkey
      """
    )
  end
end
