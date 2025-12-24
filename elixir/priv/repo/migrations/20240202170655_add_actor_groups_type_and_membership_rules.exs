defmodule Portal.Repo.Migrations.AddActorGroupsTypeAndMembershipRules do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:type, :string)
      add(:membership_rules, {:array, :map}, default: [])
    end

    execute("UPDATE actor_groups SET type = 'static'")
    execute("ALTER TABLE actor_groups ALTER COLUMN type SET NOT NULL")
  end
end
