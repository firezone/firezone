defmodule Portal.Repo.Migrations.RemovePersistentIdFromPolicies do
  use Ecto.Migration

  def change do
    alter table(:policies) do
      remove(:persistent_id, :uuid)
    end
  end
end
