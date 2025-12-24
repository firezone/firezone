defmodule Portal.Repo.Migrations.RemovePersistentIdFromResources do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      remove(:persistent_id, :uuid)
    end
  end
end
