defmodule Domain.Repo.Migrations.UpdateAuthIdentitiesProviderIdentifierIdx do
  use Ecto.Migration

  def change do
    # created in 20230425101110_create_auth_identities; covered by previous migration
    drop(
      index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        name: :auth_identities_account_id_provider_id_provider_identifier_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )
  end
end
