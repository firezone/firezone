defmodule Domain.Repo.Migrations.AddIdpFieldsToAuthIdentities do
  use Domain, :migration

  def change do
    alter table(:auth_identities) do
      add(:issuer, :text)
      add(:idp_id, :text)
      add(:password_hash, :text)
    end

    create(
      index(:auth_identities, [:account_id, :issuer, :idp_id],
        unique: true,
        name: :auth_identities_account_idp_fields_index,
        where: "issuer IS NOT NULL OR idp_id IS NOT NULL"
      )
    )
  end
end
