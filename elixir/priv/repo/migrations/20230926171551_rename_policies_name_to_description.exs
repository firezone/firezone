defmodule Portal.Repo.Migrations.RenamePoliciesNameToDescription do
  use Ecto.Migration

  def change do
    rename(table(:policies), :name, to: :description)

    alter table(:policies) do
      modify(:description, :text, null: true)
    end

    drop(index(:policies, [:account_id, :name]))
  end
end
