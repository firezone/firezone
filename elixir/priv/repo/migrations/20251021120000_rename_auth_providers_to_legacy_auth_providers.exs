defmodule Portal.Repo.Migrations.RenameAuthProvidersToLegacyAuthProviders do
  use Ecto.Migration

  def change do
    rename(table(:auth_providers), to: table(:legacy_auth_providers))
  end
end
