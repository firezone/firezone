defmodule Portal.Repo.Migrations.AlterRoleWithReplication do
  use Ecto.Migration

  def up do
    execute("ALTER ROLE CURRENT_USER WITH REPLICATION")
  end

  def down do
    execute("ALTER ROLE CURRENT_USER WITH NOREPLICATION")
  end
end
