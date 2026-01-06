defmodule Portal.Repo.Migrations.AddIndexesToActorGroupMemberships do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create(index("actor_group_memberships", [:group_id], concurrently: true))
    create(index("actor_group_memberships", [:actor_id], concurrently: true))
  end
end
