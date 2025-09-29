defmodule Domain.Repo.Migrations.CreateGoogleOidcProviders do
  use Ecto.Migration

  def change do
    create table(:google_oidc_providers, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:hosted_domain, :string, null: false)

      add(:created_by, :string, null: false)
      add(:created_by_subject, :map)
      timestamps()
    end
  end
end
