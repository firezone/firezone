defmodule Domain.Repo.Migrations.CreateUserpassAuthProviders do
  use Domain, :migration

  def change do
    create table(:userpass_auth_providers, primary_key: false) do
      account()

      add(:id, :binary_id, primary_key: true)
      add(:directory_id, :binary_id, null: false)

      add(:disabled_at, :utc_datetime_usec)

      subject_trail()
      timestamps()
    end

    create(index(:userpass_auth_providers, [:account_id], unique: true))

    up = """
    ALTER TABLE userpass_auth_providers
    ADD CONSTRAINT userpass_auth_providers_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE userpass_auth_providers
    DROP CONSTRAINT userpass_auth_providers_directory_id_fkey
    """

    execute(up, down)
  end
end
