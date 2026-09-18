defmodule Portal.Repo.Migrations.AddNestedGroupIdpIdsToGroups do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      add(:nested_group_idp_ids, {:array, :text}, null: false, default: [])
    end
  end
end
