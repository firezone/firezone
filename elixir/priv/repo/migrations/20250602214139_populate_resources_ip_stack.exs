defmodule Portal.Repo.Migrations.PopulateResourcesIpStack do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE resources
    SET ip_stack = 'dual'
      WHERE type = 'dns'
    """)
  end

  def down do
    execute("""
    UPDATE resources
    SET ip_stack = NULL
      WHERE type = 'dns'
    """)
  end
end
