defmodule Domain.Repo.Migrations.RemoveDevicesKeyRegeneratedAt do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      remove(:key_regenerated_at)
    end
  end
end
