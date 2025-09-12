defmodule Domain.Repo.Migrations.AddSyncedAtToAuthIdentities do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      add(:synced_at, :utc_datetime_usec)
    end

    create(
      index(:auth_identities, [:account_id, :provider_id, :synced_at],
        where: "synced_at IS NOT NULL"
      )
    )
  end
end
