defmodule Portal.Repo.Migrations.RemoveDeletedAtFromGatewayGroups do
  use Ecto.Migration

  def change do
    alter table(:gateway_groups) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
