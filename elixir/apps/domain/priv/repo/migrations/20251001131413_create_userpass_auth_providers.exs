defmodule Domain.Repo.Migrations.CreateUserpassAuthProviders do
  use Domain, :migration

  def change do
    create table(:userpass_auth_providers, primary_key: false) do
      account(primary_key: true)

      add(:directory_id, :binary_id, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    up = """
    ALTER TABLE userpass_auth_providers
    ADD CONSTRAINT userpass_auth_providers_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE userpass_auth_providers
    DROP CONSTRAINT userpass_auth_providers_account_directory_fk
    """

    execute(up, down)
  end
end
