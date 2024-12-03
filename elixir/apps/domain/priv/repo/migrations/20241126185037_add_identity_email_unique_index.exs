defmodule Domain.Repo.Migrations.AddIdentityEmailUniqueIndex do
  use Ecto.Migration

  def change do
    create(
      index(:auth_identities, [:provider_id, :email],
        name: :auth_identities_provider_id_email_idx,
        where: "deleted_at IS NULL",
        unique: true
      )
    )
  end
end
