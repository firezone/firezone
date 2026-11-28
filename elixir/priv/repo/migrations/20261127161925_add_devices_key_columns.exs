defmodule Portal.Repo.Migrations.AddDevicesKeyColumns do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:key_hash, :binary)
      add_if_not_exists(:ephemeral, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      remove_if_exists(:ephemeral, :boolean)
      remove_if_exists(:key_hash, :binary)
    end
  end
end
