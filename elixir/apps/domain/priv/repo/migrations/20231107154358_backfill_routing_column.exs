defmodule Domain.Repo.Migrations.BackfillRoutingColumn do
  use Ecto.Migration
  import Ecto.Query

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    from(g in "gateway_groups", select: true, where: is_nil(g.routing))
    |> Domain.Repo.update_all(set: [routing: "managed"])
  end

  def down, do: :ok
end
