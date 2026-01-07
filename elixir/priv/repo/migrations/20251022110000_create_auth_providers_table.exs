defmodule Portal.Repo.Migrations.CreateAuthProvidersTable do
  use Ecto.Migration

  def change do
    create(table(:auth_providers, primary_key: false)) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:type, :string, null: false)
    end

    create(
      constraint(:auth_providers, :type_must_be_valid,
        check: "type IN ('google', 'entra', 'okta', 'email_otp', 'oidc', 'userpass')"
      )
    )
  end
end
