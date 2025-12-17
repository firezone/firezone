defmodule Portal.Repo.Migrations.IndexPoliciesOnResourceId do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(index(:policies, [:resource_id], concurrently: true))
  end
end
