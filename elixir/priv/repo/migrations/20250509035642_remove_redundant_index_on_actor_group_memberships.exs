defmodule Portal.Repo.Migrations.RemoveRedundantIndexOnActorGroupMemberships do
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    execute("DROP INDEX CONCURRENTLY IF EXISTS actor_group_memberships_actor_id_index")
  end

  def down do
    create(index("actor_group_memberships", [:actor_id], concurrently: true))
  end
end
