defmodule Domain.Repo.Migrations.AddPoliciesConstraints do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add(:constraints, {:array, :map}, default: [])
    end
  end
end
