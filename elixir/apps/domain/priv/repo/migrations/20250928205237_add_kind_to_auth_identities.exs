defmodule Domain.Repo.Migrations.AddKindToAuthIdentities do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      add(:kind, :string)
    end

    create(
      index(:auth_identities, [:account_id, :kind, :provider_identifier],
        unique: true,
        where: "deleted_at IS NULL AND kind IS NOT NULL"
      )
    )
  end
end
