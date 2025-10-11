defmodule Domain.Repo.Migrations.AddIdpFieldsToAuthIdentities do
  use Domain, :migration

  def change do
    alter table(:auth_identities) do
      add(:issuer, :text)
      add(:idp_tenant, :text)
      add(:idp_id, :text)
    end

    create(
      index(:auth_identities, [:account_id, :issuer, :idp_tenant, :idp_id],
        unique: true,
        name: :auth_identities_account_idp_fields_index,
        where:
          "deleted_at IS NULL AND (issuer IS NOT NULL OR idp_tenant IS NOT NULL OR idp_id IS NOT NULL)"
      )
    )
  end
end
