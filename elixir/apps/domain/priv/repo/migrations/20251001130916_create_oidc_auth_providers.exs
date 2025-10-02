defmodule Domain.Repo.Migrations.CreateOidcAuthProviders do
  use Domain, :migration

  def change do
    create table(:oidc_auth_providers) do
      account(primary_key: true)

      add(:client_id, :string, null: false, primary_key: true)
      add(:client_secret, :string, null: false)
      add(:discovery_document_uri, :text, null: false)
      add(:directory_id, :binary_id, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    up = """
    ALTER TABLE oidc_auth_providers
    ADD CONSTRAINT oidc_auth_providers_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE oidc_auth_providers
    DROP CONSTRAINT oidc_auth_providers_account_directory_fk
    """

    execute(up, down)
  end
end
