defmodule Portal.Repo.Migrations.IndexPoliciesOnActorGroupId do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(index(:policies, [:actor_group_id], concurrently: true))
  end
end
