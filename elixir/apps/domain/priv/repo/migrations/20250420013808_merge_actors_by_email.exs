defmodule Domain.Repo.Migrations.MergeActorsByEmail do
  use Ecto.Migration

  def change do
    # TODO:
    # 1. Find all auth_identities with the same email within an account where deleted_at is nil
    # 2. Set the actor_id of the auth_identities to the actor_id of the first auth_identity by inserted_at
    # 3. Find all of the distinct auth_identities.email values and create a new actor_email for each
    # 4. Drop the email column from auth_identities
    # 5. Clear out emails from auth_identities.provider_identifier
    # 6. Migrate auth_identities.provider_identifier from citext back to string
    # 7. Allow provider_identifier to be null on auth_identities
    # 8. Find all auth_identities with provider_id set to the email provider
    # 9. Allow null values in auth_identities.provider_identifier
    # 10. Set provider_identifier to null for those auth_identities
  end
end
