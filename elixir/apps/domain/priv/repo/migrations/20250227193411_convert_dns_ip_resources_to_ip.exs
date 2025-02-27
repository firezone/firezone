defmodule Domain.Repo.Migrations.ConvertDnsIpResourcesToIp do
  use Ecto.Migration

  def change do
    # Convert IP addresses
    execute("""
    UPDATE resources
    SET type = 'ip'
    WHERE type = 'dns'
    AND address::inet IS NOT NULL
    AND address !~ '/'
    """)

    # Convert CIDR blocks
    execute("""
    UPDATE resources
    SET type = 'cidr'
    WHERE type = 'dns'
    AND address::inet IS NOT NULL
    AND address ~ '/'
    """)
  end
end
