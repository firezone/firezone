defmodule Portal.Repo.Migrations.CreatePgauditExtension do
  use Ecto.Migration

  def up do
    execute("""
      DO $$
      BEGIN
          CREATE EXTENSION IF NOT EXISTS pgaudit;
      EXCEPTION
          WHEN OTHERS THEN
              RAISE NOTICE 'Extension "pgaudit" is not available, skipping...';
      END;
      $$;
    """)
  end

  def down do
    execute("""
      DROP EXTENSION IF EXISTS pgaudit;
    """)
  end
end
