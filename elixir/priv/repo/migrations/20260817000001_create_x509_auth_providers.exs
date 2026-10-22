defmodule Portal.Repo.Migrations.CreateX509AuthProviders do
  use Ecto.Migration

  def up do
    drop(constraint(:auth_providers, :type_must_be_valid))

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check: "type IN ('google', 'entra', 'okta', 'email_otp', 'oidc', 'userpass', 'x509')"
      )
    )

    create(
      unique_index(:auth_providers, [:account_id],
        where: "type = 'x509'",
        name: :auth_providers_account_id_x509_index
      )
    )

    create table(:x509_auth_providers, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)

      add(:name, :string, null: false, default: "X.509")
      add(:context, :string, null: false, default: "clients_only")
      add(:is_disabled, :boolean, default: true, null: false)

      timestamps()
    end

    create(
      unique_index(:x509_auth_providers, [:account_id],
        name: :x509_auth_providers_account_id_index
      )
    )

    execute("""
    ALTER TABLE x509_auth_providers
    ADD CONSTRAINT x509_auth_providers_auth_provider_id_fkey
    FOREIGN KEY (account_id, id)
    REFERENCES auth_providers(account_id, id)
    ON DELETE CASCADE
    """)

    create(
      constraint(:x509_auth_providers, :context_must_be_clients_only,
        check: "context = 'clients_only'"
      )
    )

    execute("""
    WITH providers AS (
      SELECT id AS account_id, gen_random_uuid() AS provider_id
      FROM accounts
    ), inserted_parents AS (
      INSERT INTO auth_providers (account_id, id, type)
      SELECT account_id, provider_id, 'x509'
      FROM providers
      RETURNING account_id, id
    )
    INSERT INTO x509_auth_providers (
      account_id, id, name, context, is_disabled, inserted_at, updated_at
    )
    SELECT account_id, id, 'X.509', 'clients_only', true, NOW(), NOW()
    FROM inserted_parents
    """)
  end

  def down do
    execute("DELETE FROM auth_providers WHERE type = 'x509'")
    drop(table(:x509_auth_providers))
    drop_if_exists(
      index(:auth_providers, [:account_id], name: :auth_providers_account_id_x509_index)
    )

    drop(constraint(:auth_providers, :type_must_be_valid))

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check: "type IN ('google', 'entra', 'okta', 'email_otp', 'oidc', 'userpass')"
      )
    )
  end
end
