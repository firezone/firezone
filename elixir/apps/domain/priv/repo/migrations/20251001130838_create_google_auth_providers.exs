defmodule Domain.Repo.Migrations.CreateGoogleAuthProviders do
  use Domain, :migration

  def change do
    create table(:google_auth_providers, primary_key: false) do
      account()

      add(:id, :binary_id, primary_key: true)
      add(:directory_id, :binary_id, null: false)

      add(:name, :string, null: false)
      add(:hosted_domain, :string)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:google_auth_providers, [:account_id, :hosted_domain], unique: true))
    create(index(:google_auth_providers, [:account_id, :name], unique: true))

    up = """
    ALTER TABLE google_auth_providers
    ADD CONSTRAINT google_auth_providers_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE google_auth_providers
    DROP CONSTRAINT google_auth_providers_directory_id_fkey
    """
  end
end
