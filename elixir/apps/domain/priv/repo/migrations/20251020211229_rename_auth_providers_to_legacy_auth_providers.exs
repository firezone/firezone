defmodule Domain.Repo.Migrations.RenameAuthProvidersToLegacyAuthProviders do
  use Domain, :migration

  def change do
    rename(table(:auth_providers), to: table(:legacy_auth_providers))
  end
end
