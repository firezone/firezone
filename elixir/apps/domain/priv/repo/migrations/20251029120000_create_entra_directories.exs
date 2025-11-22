defmodule Domain.Repo.Migrations.CreateEntraDirectories do
  use Domain, :migration

  def change do
    create table(:entra_directories, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      account()
      add(:tenant_id, :string, null: false)

      add(:name, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)
      add(:sync_all_groups, :boolean, default: false, null: false)
      add(:is_verified, :boolean, default: false, null: false)

      subject_trail()
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
