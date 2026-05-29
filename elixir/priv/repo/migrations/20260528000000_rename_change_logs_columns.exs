defmodule Portal.Repo.Migrations.RenameChangeLogsColumns do
  use Ecto.Migration

  # Renames the change_logs columns to match the public REST API field names.
  # Postgres rewrites the `valid_data_for_operation` check constraint to track
  # these renames automatically, and no index references the renamed columns.
  def up do
    rename(table(:change_logs), :op, to: :operation)
    rename(table(:change_logs), :table, to: :object)
    rename(table(:change_logs), :old_data, to: :before)
    rename(table(:change_logs), :data, to: :after)
  end

  def down do
    rename(table(:change_logs), :operation, to: :op)
    rename(table(:change_logs), :object, to: :table)
    rename(table(:change_logs), :before, to: :old_data)
    rename(table(:change_logs), :after, to: :data)
  end
end
