defmodule Domain.Repo.Migrations.CreateOktaAuthProviders do
  use Domain, :migration

  def change do
    create table(:okta_auth_providers, primary_key: false) do
      account(primary_key: true)

      add(:org_domain, :string, null: false, primary_key: true)
      add(:client_id, :string, null: false)
      add(:client_secret, :string, null: false)
      add(:directory_id, :binary_id, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    up = """
    ALTER TABLE okta_auth_providers
    ADD CONSTRAINT okta_auth_providers_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE okta_auth_providers
    DROP CONSTRAINT okta_auth_providers_account_directory_fk
    """

    execute(up, down)
  end
end
