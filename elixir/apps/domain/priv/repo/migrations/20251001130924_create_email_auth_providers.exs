defmodule Domain.Repo.Migrations.CreateEmailAuthProviders do
  use Domain, :migration

  def change do
    create table(:email_auth_providers) do
      account(primary_key: true)

      add(:directory_id, :binary_id, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    up = """
    ALTER TABLE email_auth_providers
    ADD CONSTRAINT email_auth_providers_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE email_auth_providers
    DROP CONSTRAINT email_auth_providers_account_directory_fk
    """

    execute(up, down)
  end
end
