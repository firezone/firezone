defmodule Domain.Repo.Migrations.AddIncludedAtToActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:included_at, :utc_datetime_usec)
    end

    alter table(:auth_providers) do
      add(:group_filters_enabled_at, :utc_datetime_usec)
    end
  end
end
