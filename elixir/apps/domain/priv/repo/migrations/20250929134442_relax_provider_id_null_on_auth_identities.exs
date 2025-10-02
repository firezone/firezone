defmodule Domain.Repo.Migrations.RelaxProviderIdNullOnAuthIdentities do
  use Domain, :migration

  def change do
    drop(
      index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        unique: true,
        where: "deleted_at IS NULL",
        name: :auth_identities_account_id_provider_id_provider_identifier_idx
      )
    )

    drop(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        unique: true,
        where: "deleted_at IS NULL",
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx
      )
    )

    alter table(:auth_identities) do
      modify(:provider_id, :binary_id, null: true, from: {:binary_id, null: false})
    end

    create(
      index(:auth_identities, [:account_id, :provider_id, :provider_identifier],
        unique: true,
        where: "deleted_at IS NULL AND provider_id IS NOT NULL",
        name: :auth_identities_account_id_provider_id_provider_identifier_idx
      )
    )

    create(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        unique: true,
        where: "deleted_at IS NULL AND provider_id IS NOT NULL",
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx
      )
    )
  end
end
