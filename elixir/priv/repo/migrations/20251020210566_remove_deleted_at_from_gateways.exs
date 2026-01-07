defmodule Portal.Repo.Migrations.RemoveDeletedAtFromGateways do
  use Ecto.Migration

  def change do
    alter table(:gateways) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
