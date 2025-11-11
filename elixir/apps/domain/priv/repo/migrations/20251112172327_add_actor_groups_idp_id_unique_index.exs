defmodule Domain.Repo.Migrations.AddActorGroupsIdpIdUniqueIndex do
  use Ecto.Migration

  def change do
    create(
      index(:actor_groups, [:account_id, :idp_id],
        unique: true,
        name: :actor_groups_account_id_idp_id_index,
        where: "idp_id IS NOT NULL"
      )
    )
  end
end
