defmodule Portal.Repo.Migrations.CreateEntraDirectories do
  use Ecto.Migration

  def change do
    create table(:entra_directories, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:tenant_id, :string, null: false)

      add(:name, :string, null: false)
      add(:errored_at, :utc_datetime_usec)
      add(:synced_at, :utc_datetime_usec)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      add(:sync_all_groups, :boolean, default: false, null: false)
      add(:is_verified, :boolean, default: false, null: false)

      add(:created_by, :string, null: false)
      add(:created_by_subject, :map)
      timestamps()
    end

    create(
      index(:entra_directories, [:account_id, :tenant_id],
        name: :entra_directories_account_id_tenant_id_index,
        unique: true
      )
    )

    create(
      index(:entra_directories, [:account_id, :name],
        name: :entra_directories_account_id_name_index,
        unique: true
      )
    )

    execute(
      """
      ALTER TABLE entra_directories
      ADD CONSTRAINT entra_directories_directory_id_fkey
      FOREIGN KEY (account_id, id)
      REFERENCES directories(account_id, id)
      ON DELETE CASCADE
      """,
      """
      ALTER TABLE entra_directories
      DROP CONSTRAINT entra_directories_directory_id_fkey
      """
    )
  end
end
