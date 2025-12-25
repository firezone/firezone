defmodule Portal.Repo.Migrations.RemoveDeletedAtFromRelayGroups do
  use Ecto.Migration

  def change do
    alter table(:relay_groups) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
