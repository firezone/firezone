defmodule Domain.Repo.Migrations.AddExcludedAtToActorAndGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:excluded_at, :utc_datetime_usec)
    end

    alter table(:actors) do
      add(:excluded_at, :utc_datetime_usec)
    end

    drop(index(:actor_groups, [:account_id]))
    drop(index(:actor_groups, [:account_id, :name]))
    drop(index(:actors, [:account_id]))

    create(
      index(:actor_groups, [:account_id], where: "excluded_at IS NULL AND deleted_at IS NULL")
    )

    create(
      index(:actor_groups, [:account_id, :name],
        where: "excluded_at IS NULL AND deleted_at IS NULL"
      )
    )

    create(index(:actors, [:account_id], where: "excluded_at IS NULL AND deleted_at IS NULL"))
  end
end
