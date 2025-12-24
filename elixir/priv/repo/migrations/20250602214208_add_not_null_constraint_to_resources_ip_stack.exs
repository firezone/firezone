defmodule Portal.Repo.Migrations.AddNotNullConstraintToResourcesIpStack do
  use Ecto.Migration

  def up do
    # Add the CHECK constraint with NOT VALID to avoid locking
    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT resources_ip_stack_not_null
    CHECK (
      (type = 'dns' AND ip_stack IN ('dual', 'ipv4_only', 'ipv6_only')) OR
      (type != 'dns' AND ip_stack IS NULL)
    ) NOT VALID
    """)

    # Validate the constraint separately
    execute("""
    ALTER TABLE resources
    VALIDATE CONSTRAINT resources_ip_stack_not_null
    """)
  end

  def down do
    # Remove the constraint
    execute("""
    ALTER TABLE resources
    DROP CONSTRAINT resources_ip_stack_not_null
    """)
  end
end
