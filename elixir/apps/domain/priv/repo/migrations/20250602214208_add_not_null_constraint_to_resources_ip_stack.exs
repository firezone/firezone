defmodule Domain.Repo.Migrations.AddNotNullConstraintToResourcesIpStack do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE resources
    ADD CONSTRAINT resources_ip_stack_not_null
    CHECK (
      (type = 'dns' AND ip_stack IN ('dual', 'ipv4_only', 'ipv6_only')) OR
      (type != 'dns' AND ip_stack IS NULL)
    )
    """)
  end

  def down do
    # Remove the not null constraint
    execute("""
    ALTER TABLE resources
    DROP CONSTRAINT resources_ip_stack_not_null
    """)
  end
end
