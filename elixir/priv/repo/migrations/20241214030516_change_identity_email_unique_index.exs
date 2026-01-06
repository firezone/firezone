defmodule Portal.Repo.Migrations.ChangeIdentityEmailUniqueIndex do
  use Ecto.Migration

  # We need to rename the index because the "add_identity_email_unique_index" originally
  # succeeded on staging but failed on production, so we need this migration to resolve
  # the difference between the two environments.
  def change do
    drop(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_account_id_provider_id_email_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )

    create(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_acct_id_provider_id_email_prov_ident_unique_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )
  end
end
