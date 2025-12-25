defmodule Portal.Repo.Migrations.IndexAuthIdentitiesOnActorId do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    create_if_not_exists(index(:auth_identities, [:actor_id], concurrently: true))
  end

  def down do
    drop_if_exists(index(:auth_identities, [:actor_id], concurrently: true))
  end
end
