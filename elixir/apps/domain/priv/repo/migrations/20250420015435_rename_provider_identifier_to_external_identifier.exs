defmodule Domain.Repo.Migrations.RenameProviderIdentifierToExternalIdentifier do
  use Ecto.Migration

  def change do
    # TODO:
    # 1. Rename identities.provider_identifier to identities.external_identifier
    # 2. Rename actor_groups.provider_identifier to actor_groups.external_identifier
  end
end
