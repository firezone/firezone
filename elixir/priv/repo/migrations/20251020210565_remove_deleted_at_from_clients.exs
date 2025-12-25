defmodule Portal.Repo.Migrations.RemoveDeletedAtFromClients do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
