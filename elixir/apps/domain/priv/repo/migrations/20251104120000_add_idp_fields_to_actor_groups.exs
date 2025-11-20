defmodule Domain.Repo.Migrations.AddIdpFieldsToActorGroups do
  use Domain, :migration

  def change do
    alter table(:actor_groups) do
      add(:directory, :text)
      add(:idp_id, :text)
    end
  end
end
