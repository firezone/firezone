defmodule Portal.Repo.Migrations.ChangeAuthIdentitiesProviderIdentifierToCitext do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS citext")

    alter table(:auth_identities) do
      modify(:provider_identifier, :citext)
    end
  end
end
