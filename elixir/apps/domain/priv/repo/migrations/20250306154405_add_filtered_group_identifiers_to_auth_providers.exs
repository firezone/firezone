defmodule Domain.Repo.Migrations.AddFilteredAtToActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      add(:filtered_at, :utc_datetime_usec)
    end

    create(
      index(:actor_groups, [:account_id, :provider_id, :filtered_at])
  end
end
