defmodule Portal.Repo.Migrations.AppendDefaultNetmaskToEmptyCidr do
  use Ecto.Migration

  def change do
    # Update the netmask of all empty IPv4 CIDR columns to 32
    execute("""
      UPDATE resources
      SET address = address || '/32'
      WHERE type = 'cidr'
        AND address !~ '/'
        AND address ~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    """)

    # Update the netmask of all empty IPv6 CIDR columns to 128
    execute("""
      UPDATE resources
      SET address = address || '/128'
      WHERE type = 'cidr'
        AND address !~ '/'
        AND address ~ '^[0-9a-fA-F:]+$'
    """)
  end
end
