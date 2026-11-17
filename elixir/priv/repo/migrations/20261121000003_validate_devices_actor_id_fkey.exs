defmodule Portal.Repo.Migrations.ValidateDevicesActorIdFkey do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")
    execute("ALTER TABLE devices VALIDATE CONSTRAINT devices_actor_id_fkey")
  end

  def down, do: :ok
end
