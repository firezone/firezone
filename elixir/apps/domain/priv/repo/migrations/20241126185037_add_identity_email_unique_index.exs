defmodule Domain.Repo.Migrations.AddIdentityEmailUniqueIndex do
  use Ecto.Migration

  def change do
    create(
      index(:auth_identities, [:account_id, :provider_id, :email],
        name: :auth_identities_account_id_provider_id_email_idx,
        where: "deleted_at IS NULL AND email IS NOT NULL",
        unique: true
      )
    )
  end
end
