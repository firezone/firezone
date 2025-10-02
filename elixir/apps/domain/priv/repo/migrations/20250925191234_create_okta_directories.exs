defmodule Domain.Repo.Migrations.CreateOktaDirectories do
  use Domain, :migration

  def change do
    create table(:okta_directories, primary_key: false) do
      account()

      add(:directory_id, :binary_id, primary_key: true)
      add(:org_domain, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:okta_directories, [:account_id, :org_domain], unique: true))

    # Lock directories to account
    up = """
    ALTER TABLE okta_directories
    ADD CONSTRAINT okta_directories_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE okta_directories
    DROP CONSTRAINT okta_directories_account_directory_fk
    """

    execute(up, down)
  end
end
