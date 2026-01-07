defmodule Portal.Repo.Migrations.RemoveMembershipRules do
  use Ecto.Migration

  def up do
    alter table(:actor_groups) do
      remove(:membership_rules)
    end
  end

  def down do
    alter table(:actor_groups) do
      add(:membership_rules, {:array, :map}, default: [])
    end
  end
end
