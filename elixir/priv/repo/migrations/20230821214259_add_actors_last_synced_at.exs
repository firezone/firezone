defmodule Portal.Repo.Migrations.AddActorsLastSyncedAt do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
