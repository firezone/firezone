defmodule Domain.Repo.Migrations.CreateGoogleDirectories do
  use Domain, :migration

  def change do
    create table(:google_directories, primary_key: false) do
      account()

      # Enforce 1:1 relationship with directories table
      add(:directory_id, :binary_id, primary_key: true)
      add(:hosted_domain, :string, null: false)
      add(:error_count, :integer, null: false, default: 0)
      add(:synced_at, :utc_datetime_usec)
      add(:disabled_at, :utc_datetime_usec)
      add(:disabled_reason, :string)
      add(:error, :text)
      add(:error_emailed_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:google_directories, [:account_id, :hosted_domain], unique: true))

    # Lock directories to account
    up = """
    ALTER TABLE google_directories
    ADD CONSTRAINT auth_identities_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE google_directories
    DROP CONSTRAINT auth_identities_account_directory_fk
    """

    execute(up, down)
  end
end
