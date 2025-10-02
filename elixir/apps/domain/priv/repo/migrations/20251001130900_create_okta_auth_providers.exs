defmodule Domain.Repo.Migrations.CreateOktaAuthProviders do
  use Domain, :migration

  def change do
    create table(:okta_auth_providers, primary_key: false) do
      account()

      add(:id, :binary_id, primary_key: true)
      add(:directory_id, :binary_id, null: false)

      add(:name, :string, null: false)
      add(:org_domain, :string, null: false)
      add(:client_id, :string, null: false)
      add(:client_secret, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:okta_auth_providers, [:account_id, :org_domain], unique: true))
    create(index(:okta_auth_providers, [:account_id, :name], unique: true))

    up = """
    ALTER TABLE okta_auth_providers
    ADD CONSTRAINT okta_auth_providers_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE okta_auth_providers
    DROP CONSTRAINT okta_auth_providers_directory_id_fkey
    """

    execute(up, down)
  end
end
