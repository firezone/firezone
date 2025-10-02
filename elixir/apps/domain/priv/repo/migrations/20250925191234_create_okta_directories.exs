defmodule Domain.Repo.Migrations.CreateOktaDirectories do
  use Domain, :migration

  def change do
    create table(:okta_directories, primary_key: false) do
      account()

      add(:directory_id, :binary_id, null: false, primary_key: true)

      add(:name, :string, null: false)
      add(:org_domain, :string, null: false)
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

    create(index(:okta_directories, [:account_id, :org_domain], unique: true))
    create(index(:okta_directories, [:account_id, :name], unique: true))

    up = """
    ALTER TABLE okta_directories
    ADD CONSTRAINT okta_directories_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE okta_directories
    DROP CONSTRAINT okta_directories_directory_id_fkey
    """
  end
end
