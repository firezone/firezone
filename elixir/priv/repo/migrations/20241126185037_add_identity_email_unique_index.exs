defmodule Portal.Repo.Migrations.AddIdentityEmailUniqueIndex do
  use Ecto.Migration

  def change do
    # We include provider_identifier in the index because it's possible
    # for two identities in the same provider to share an email address.
    #
    # This can happen for example if the IdP allows auth methods on their
    # end tied to a single OIDC connector with Firezone. Examples of IdPs
    # that do this are Authelia, Auth0, Keycloak and likely others.
    create(
      index(:auth_identities, [:account_id, :provider_id, :email, :provider_identifier],
        name: :auth_identities_account_id_provider_id_email_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )
  end
end
