defmodule Domain.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:directory, :string)
      add(:idp_id, :text)
    end

    create(
      index(:actor_groups, [:account_id, :directory, :idp_id],
        unique: true,
        name: :actor_groups_account_idp_fields_index,
        where: "directory <> 'firezone'"
      )
    )
  end
end
