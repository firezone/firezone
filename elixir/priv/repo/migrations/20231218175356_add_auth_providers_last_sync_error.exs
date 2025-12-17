defmodule Portal.Repo.Migrations.AddAuthProvidersLastSyncError do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:last_syncs_failed, :integer, default: 0)
      add(:last_sync_error, :text)
    end
  end
end
