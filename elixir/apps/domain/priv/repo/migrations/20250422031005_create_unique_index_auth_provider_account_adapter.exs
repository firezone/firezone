defmodule Domain.Repo.Migrations.CreateUniqueIndexAuthProviderAccountAdapter do
  use Ecto.Migration

  def change do
    create(
      index(:auth_providers, [:account_id, :adapter],
        unique: true,
        name: :unique_account_adapter_index,
        where:
          "deleted_at IS NULL AND adapter IN ('google_workspace', 'okta', 'jumpcloud', 'microsoft_entra')"
      )
    )
  end
end
