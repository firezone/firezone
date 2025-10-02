defmodule Domain.Repo.Migrations.CreateEntraAuthProviders do
  use Domain, :migration

  def change do
    create table(:entra_auth_providers, primary_key: false) do
      account()

      add(:id, :binary_id, primary_key: true)
      add(:directory_id, :binary_id, null: false)

      add(:name, :string, null: false)
      add(:tenant_id, :string, null: false)
      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:entra_auth_providers, [:account_id, :tenant_id], unique: true))
    create(index(:entra_auth_providers, [:account_id, :name], unique: true))

    up = """
    ALTER TABLE entra_auth_providers
    ADD CONSTRAINT entra_auth_providers_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE entra_auth_providers
    DROP CONSTRAINT entra_auth_providers_directory_id_fkey
    """

    execute(up, down)
  end
end
