defmodule Portal.Repo.Migrations.AddPosturesToPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      add(:postures, :map)
    end
  end
end
