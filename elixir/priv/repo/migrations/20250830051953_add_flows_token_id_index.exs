defmodule Portal.Repo.Migrations.AddFlowsTokenIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(index(:flows, [:token_id]))
  end
end
