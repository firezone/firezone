defmodule Domain.Repo.Migrations.AddExcludedAtToActorGroupsAndAuthIdentities do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:excluded_at, :utc_datetime_usec)
    end

    alter table(:auth_identities) do
      add(:excluded_at, :utc_datetime_usec)
    end

    # Re-create; used to fetch all non-excluded groups for an account
    drop(index(:actor_groups, [:account_id]))

    create(
      index(:actor_groups, [:account_id], where: "excluded_at IS NULL AND deleted_at IS NULL")
    )
  end
end
