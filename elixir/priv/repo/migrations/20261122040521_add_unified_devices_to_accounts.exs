defmodule Portal.Repo.Migrations.AddUnifiedDevicesToAccounts do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:accounts) do
      add_if_not_exists(:unified_devices, :boolean)
    end
  end

  def down do
    alter table(:accounts) do
      remove_if_exists(:unified_devices, :boolean)
    end
  end
end
