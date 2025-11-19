defmodule Domain.Repo.Migrations.MigrateToNewAuthSystem do
  use Domain, :migration

  def up do
    # This migration converts all accounts from the legacy auth system to the new directory-based system
    # The actual migration logic is in the accompanying SQL file
    sql_file = Path.join([__DIR__, "20251104130000_migrate_to_new_auth_system.sql"])
    sql_content = File.read!(sql_file)
    execute(sql_content)
  end

  def down do
    raise "Irreversible migration"
  end
end
