defmodule Portal.Repo.Migrations.AddActorGroupsCreatedBy do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end
  end
end
