defmodule Domain.Repo.Migrations.CreateOidcAuthProviders do
  use Domain, :migration

  def change do
    create table(:oidc_auth_providers, primary_key: false) do
      account()

      add(:id, :binary_id, primary_key: true)
      add(:directory_id, :binary_id, null: false)

      add(:name, :string, null: false)
      add(:client_id, :string, null: false)
      add(:client_secret, :string, null: false)
      add(:discovery_document_uri, :text, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:oidc_auth_providers, [:account_id, :client_id], unique: true))
    create(index(:oidc_auth_providers, [:account_id, :name], unique: true))

    up = """
    ALTER TABLE oidc_auth_providers
    ADD CONSTRAINT oidc_auth_providers_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE oidc_auth_providers
    DROP CONSTRAINT oidc_auth_providers_directory_id_fkey
    """

    execute(up, down)
  end
end
