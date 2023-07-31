defmodule Domain.Repo.Migrations.CreateActorGroups do
  use Ecto.Migration

  def change do
    create table(:actor_groups, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:name, :string)

      add(:provider_id, references(:auth_providers, type: :binary_id, on_delete: :delete_all))
      add(:provider_identifier, :string)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:actor_groups, :provider_fields_not_null,
        check: """
        (provider_id IS NOT NULL AND provider_identifier IS NOT NULL)
        OR (provider_id IS NULL AND provider_identifier IS NULL)
        """
      )
    )

    create(index(:actor_groups, [:account_id], where: "deleted_at IS NULL"))

    create(
      index(:actor_groups, [:account_id, :name],
        unique: true,
        where: "deleted_at IS NULL AND provider_id IS NULL AND provider_identifier IS NULL"
      )
    )

    create(
      index(:actor_groups, [:account_id, :provider_id, :provider_identifier],
        unique: true,
        where:
          "deleted_at IS NULL AND provider_id IS NOT NULL AND provider_identifier IS NOT NULL"
      )
    )

    create table(:actor_group_memberships, primary_key: false) do
      add(:actor_id, references(:actors, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:group_id, references(:actor_groups, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:account_id, references(:accounts, type: :binary_id), null: false)
    end
  end
end
