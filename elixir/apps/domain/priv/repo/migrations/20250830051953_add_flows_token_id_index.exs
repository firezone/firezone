defmodule Domain.Repo.Migrations.AddFlowsTokenIdIndex do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create(index(:flows, [:token_id]))
  end
end
