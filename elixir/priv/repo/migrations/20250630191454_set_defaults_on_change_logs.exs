defmodule Portal.Repo.Migrations.SetDefaultsOnChangeLogs do
  use Ecto.Migration

  def up do
    alter table(:change_logs) do
      modify(:inserted_at, :utc_datetime_usec, default: fragment("now()"))
      modify(:id, :binary_id, default: fragment("gen_random_uuid()"))
    end
  end

  def down do
    alter table(:change_logs) do
      modify(:inserted_at, :utc_datetime_usec, default: nil)
      modify(:id, :binary_id, default: nil)
    end
  end
end
