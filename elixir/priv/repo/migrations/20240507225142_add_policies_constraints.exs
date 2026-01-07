defmodule Portal.Repo.Migrations.AddPoliciesConditions do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add(:conditions, {:array, :map}, default: [])
    end
  end
end
