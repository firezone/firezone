defmodule Domain.Repo.Migrations.AddCreatedByFields do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:auth_identities) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:gateway_groups) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:gateway_tokens) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:relay_groups) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:relay_tokens) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:resources) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end

    alter table(:resource_connections) do
      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
    end
  end
end
