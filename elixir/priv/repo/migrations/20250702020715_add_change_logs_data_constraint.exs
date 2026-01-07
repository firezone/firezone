defmodule Portal.Repo.Migrations.AddChangeLogsDataConstraint do
  use Ecto.Migration

  def change do
    create(
      constraint(:change_logs, :valid_data_for_operation,
        check: """
        CASE op
          WHEN 'insert' THEN data IS NOT NULL AND old_data IS NULL
          WHEN 'update' THEN data IS NOT NULL AND old_data IS NOT NULL
          WHEN 'delete' THEN data IS NULL AND old_data IS NOT NULL
          ELSE false
        END
        """
      )
    )
  end
end
