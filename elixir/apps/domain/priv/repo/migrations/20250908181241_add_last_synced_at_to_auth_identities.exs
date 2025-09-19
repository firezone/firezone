defmodule Domain.Repo.Migrations.AddLastSyncedAtToAuthIdentities do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
