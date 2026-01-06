defmodule Portal.Repo.Migrations.MigrateToNewAuthSystem do
  use Ecto.Migration

  def up do
    # This migration converts all accounts from the legacy auth system to the new directory-based system
    # The actual migration logic is in the accompanying SQL file
    sql_content = File.read!(sql_file())
    execute(sql_content)
  end

  defp sql_file do
    filename =
      __ENV__.file
      |> Path.basename()
      |> String.replace(".exs", ".sql")

    Path.join(__DIR__, filename)
  end

  def down do
    # Irreversible migration
  end
end
