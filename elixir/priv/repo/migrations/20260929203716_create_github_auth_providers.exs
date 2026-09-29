defmodule Portal.Repo.Migrations.CreateGithubAuthProviders do
  use Ecto.Migration

  def up do
    drop(constraint(:auth_providers, :type_must_be_valid))

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check:
          "type IN ('google', 'github', 'entra', 'okta', 'email_otp', 'oidc', 'userpass', 'x509')"
      )
    )

    create table(:github_auth_providers, primary_key: false) do
      add(:id, :binary_id, null: false, primary_key: true)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:context, :string, null: false)
      add(:client_session_lifetime_secs, :integer)
      add(:portal_session_lifetime_secs, :integer)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:is_default, :boolean, default: false, null: false)

      add(:issuer, :text, null: false)
      add(:name, :string, null: false)

      timestamps()
    end

    create(
      unique_index(:github_auth_providers, [:account_id],
        name: :github_auth_providers_account_id_index
      )
    )

    execute("""
    ALTER TABLE github_auth_providers
    ADD CONSTRAINT github_auth_providers_auth_provider_id_fkey
    FOREIGN KEY (account_id, id)
    REFERENCES auth_providers(account_id, id)
    ON DELETE CASCADE
    """)

    create(
      constraint(:github_auth_providers, :context_must_be_valid,
        check: "context IN ('clients_and_portal', 'clients_only', 'portal_only')"
      )
    )
  end

  def down do
    execute("DELETE FROM auth_providers WHERE type = 'github'")
    drop(table(:github_auth_providers))

    drop(constraint(:auth_providers, :type_must_be_valid))

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check: "type IN ('google', 'entra', 'okta', 'email_otp', 'oidc', 'userpass', 'x509')"
      )
    )
  end
end
