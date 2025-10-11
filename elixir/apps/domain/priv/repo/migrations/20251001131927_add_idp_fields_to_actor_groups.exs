defmodule Domain.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:issuer, :text)
      add(:idp_tenant, :text)
      add(:idp_id, :text)
    end

    create(
      index(:actor_groups, [:account_id, :issuer, :idp_tenant, :idp_id],
        unique: true,
        name: :actor_groups_account_idp_fields_index,
        where:
          "deleted_at IS NULL AND (issuer IS NOT NULL OR idp_tenant IS NOT NULL OR idp_id IS NOT NULL)"
      )
    )
  end
end
