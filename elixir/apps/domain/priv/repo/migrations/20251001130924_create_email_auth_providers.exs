defmodule Domain.Repo.Migrations.CreateEmailAuthProviders do
  use Domain, :migration

  def change do
    create table(:email_auth_providers, primary_key: false) do
      account()

      add(:id, :binary_id, primary_key: true)
      add(:directory_id, :binary_id, null: false)

      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:email_auth_providers, [:account_id], unique: true))

    up = """
    ALTER TABLE email_auth_providers
    ADD CONSTRAINT email_auth_providers_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE email_auth_providers
    DROP CONSTRAINT email_auth_providers_directory_id_fkey
    """

    execute(up, down)
  end
end
