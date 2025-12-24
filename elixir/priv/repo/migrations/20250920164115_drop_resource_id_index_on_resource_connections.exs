defmodule Portal.Repo.Migrations.DropResourceIdIndexOnResourceConnections do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    # redundant with the (resource_id, gateway_group_id) index
    drop_if_exists(index(:resource_connections, [:resource_id], concurrently: true))
  end
end
