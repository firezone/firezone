defmodule Portal.Repo.Migrations.AddExternalIdentitiesActorDirectoryUniqueIndex do
  use Ecto.Migration

  def up do
    create(
      unique_index(:external_identities, [:account_id, :actor_id, :directory_id],
        name: :external_identities_account_id_actor_id_directory_id_index,
        where: "directory_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      unique_index(:external_identities, [:account_id, :actor_id, :directory_id],
        name: :external_identities_account_id_actor_id_directory_id_index,
        where: "directory_id IS NOT NULL"
      )
    )
  end
end
