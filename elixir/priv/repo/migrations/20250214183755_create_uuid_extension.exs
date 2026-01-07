defmodule Portal.Repo.Migrations.CreateUuidExtension do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS \"uuid-ossp\"")
  end
end
