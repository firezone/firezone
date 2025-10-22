defmodule Domain.Repo.Migrations.RemoveDeletedAtFromActorGroups do
  use Ecto.Migration

  def change do
    alter table(:actor_groups) do
      remove(:deleted_at, :utc_datetime_usec)
    end
  end
end
