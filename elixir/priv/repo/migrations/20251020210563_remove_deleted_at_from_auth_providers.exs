defmodule Portal.Repo.Migrations.RemoveDeletedAtFromAuthProviders do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
