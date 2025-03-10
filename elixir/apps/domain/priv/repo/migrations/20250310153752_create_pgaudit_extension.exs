defmodule Domain.Repo.Migrations.CreatePgauditExtension do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pgaudit"
  end

  def down do
    execute "DROP EXTENSION IF EXISTS pgaudit"
  end
end
