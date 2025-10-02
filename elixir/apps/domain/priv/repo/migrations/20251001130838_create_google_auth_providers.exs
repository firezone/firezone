defmodule Domain.Repo.Migrations.CreateGoogleAuthProviders do
  use Domain, :migration

  def change do
    create table(:google_auth_providers, primary_key: false) do
      account(primary_key: true)

      add(:hosted_domain, :string, null: false, primary_key: true)
      add(:directory_id, :binary_id, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    up = """
    ALTER TABLE google_auth_providers
    ADD CONSTRAINT google_auth_providers_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE google_auth_providers
    DROP CONSTRAINT google_auth_providers_account_directory_fk
    """

    execute(up, down)
  end
end
