defmodule Portal.Repo.Migrations.RemoveDeletedAtFromResources do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
