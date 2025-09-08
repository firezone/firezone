defmodule Domain.Repo.Migrations.AddSyncedAtToAuthIdentities do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      add(:synced_at, :utc_datetime_usec)
    end
  end
end
