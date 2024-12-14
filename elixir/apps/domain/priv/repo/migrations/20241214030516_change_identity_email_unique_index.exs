defmodule Domain.Repo.Migrations.ChangeIdentityEmailUniqueIndex do
  use Ecto.Migration

  def change do
    drop(
      index(:auth_identities, [:account_id, :provider_id, :email],
        name: :auth_identities_account_id_provider_id_email_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )

    # We include provider_identifier in the index because it's possible
    # for two identities in the same provider to share an email address.
    #
    # This can happen for example if the IdP allows auth methods on their
    # end tied to a single OIDC connector with Firezone. Examples of IdPs
    # that do this are Authelia, Auth0, Keycloak and likely others.
    #
    # Since we want to allow the admin to create identities by email and have
    # the provider_identifier populated on first sign-in, we need to enforce
    # the uniqueness of email and provider_identifier together only when
    # provider_identifier is NULL. This removes ambiguity about which identity
    # to match when a user signs in for the first time.

    # Create a new index that treats NULLs in `provider_identifier` appropriately
    create(
      index(:auth_identities, [:account_id, :provider_id, :email],
        name: :auth_identities_acct_id_provider_id_email_unique_null_idx,
        where: "deleted_at IS NULL AND provider_identifier IS NULL",
        unique: true
      )
    )

    # Create another index to handle non-NULL `provider_identifier` values
    create(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_acct_id_prov_id_email_prov_identifier_unique_idx,
        where: "deleted_at IS NULL AND provider_identifier IS NOT NULL",
        unique: true
      )
    )
  end
end
