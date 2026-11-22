defmodule Portal.Repo.Migrations.AllowDevicesWithoutType do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      modify(:type, :string, null: true, from: {:string, null: false})
    end
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      modify(:type, :string, null: false, from: {:string, null: true})
    end
  end
end
