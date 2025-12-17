defmodule Portal.Repo.Migrations.AddDefaultPersistentId do
  use Ecto.Migration

  def up do
    # Add default UUID generation for resources.persistent_id
    execute("""
    ALTER TABLE resources
    ALTER COLUMN persistent_id SET DEFAULT gen_random_uuid()
    """)

    # Add default UUID generation for policies.persistent_id
    execute("""
    ALTER TABLE policies
    ALTER COLUMN persistent_id SET DEFAULT gen_random_uuid()
    """)
  end

  def down do
    # Remove default for resources.persistent_id
    execute("""
    ALTER TABLE resources
    ALTER COLUMN persistent_id DROP DEFAULT
    """)

    # Remove default for policies.persistent_id
    execute("""
    ALTER TABLE policies
    ALTER COLUMN persistent_id DROP DEFAULT
    """)
  end
end
