defmodule Domain.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:issuer, :text)
      add(:idp_id, :text)
    end

    create(
      index(:actor_groups, [:account_id, :issuer, :idp_id],
        unique: true,
        name: :actor_groups_account_idp_fields_index,
        where: "issuer <> 'firezone'"
      )
    )
  end
end
