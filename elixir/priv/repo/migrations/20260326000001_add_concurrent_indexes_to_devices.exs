defmodule Portal.Repo.Migrations.AddConcurrentIndexesToDevices do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create(index(:devices, [:account_id, :type], concurrently: true))
  end
end
