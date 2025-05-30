defmodule Domain.Repo.Migrations.SetIpStackOnResources do
  use Ecto.Migration

  def up do
    # Populate default value for ip_stack based on existing data
    execute("""
      UPDATE resources
      SET ip_stack =
        CASE
          WHEN type IN ('internet', 'dns') THEN 'dual'
          WHEN type IN ('cidr', 'ip') THEN
            CASE
              WHEN family(address::inet) = 4 THEN 'ipv4_only'
              WHEN family(address::inet) = 6 THEN 'ipv6_only'
              ELSE 'dual'
            END
          ELSE 'dual'
        END
    """)
  end

  def down do
    execute("""
      UPDATE resources
      SET ip_stack = NULL
    """)
  end
end
