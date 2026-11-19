defmodule Portal.Repo.Migrations.DropDevicesActorId do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      remove_if_exists(:actor_id, :binary_id)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:actor_id, :binary_id)
    end
  end
end
