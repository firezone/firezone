defmodule Portal.Repo.Migrations.RemoveDeletedAtFromActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
