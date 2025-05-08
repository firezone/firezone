defmodule Domain.Repo.Migrations.AddIndexesToActorGroupMemberships do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create(index("actor_group_memberships", [:group_id], concurrently: true))
    create(index("actor_group_memberships", [:actor_id], concurrently: true))
  end
end
