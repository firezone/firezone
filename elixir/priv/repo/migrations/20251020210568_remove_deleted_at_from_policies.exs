defmodule Portal.Repo.Migrations.RemoveDeletedAtFromPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
