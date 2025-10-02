defmodule Domain.Repo.Migrations.CreateEntraDirectories do
  use Domain, :migration

  def change do
    create table(:entra_directories, primary_key: false) do
      account()

      add(:directory_id, :binary_id, null: false, primary_key: true)

      add(:name, :string, null: false)
      add(:tenant_id, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)
      add(:jit_provisioning, :boolean, default: false, null: false)

      subject_trail()
      timestamps()
    end

    create(index(:entra_directories, [:account_id, :tenant_id], unique: true))
    create(index(:entra_directories, [:account_id, :name], unique: true))

    # Lock directories to account
    up = """
    ALTER TABLE entra_directories
    ADD CONSTRAINT entra_directories_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE entra_directories
    DROP CONSTRAINT entra_directories_account_directory_fk
    """

    execute(up, down)
  end
end
