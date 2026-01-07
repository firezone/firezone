defmodule Portal.Repo.Migrations.ConvertDnsIpResourcesToIp do
  use Ecto.Migration

  def change do
    # Postgres doesn't natively support try_cast, but we can define our own
    execute("""
    CREATE OR REPLACE FUNCTION try_cast_inet(text) RETURNS inet AS $$
    BEGIN
      RETURN $1::inet;
    EXCEPTION
      WHEN OTHERS THEN
        RETURN NULL;
    END;
    $$ LANGUAGE plpgsql
    """)

    # Convert IP addresses
    execute("""
    UPDATE resources
    SET type = 'ip'
    WHERE type = 'dns'
    AND try_cast_inet(address) IS NOT NULL
    AND address !~ '/'
    """)

    # Convert CIDR blocks
    execute("""
    UPDATE resources
    SET type = 'cidr'
    WHERE type = 'dns'
    AND try_cast_inet(address) IS NOT NULL
    AND address ~ '/'
    """)

    execute("""
    DROP FUNCTION IF EXISTS try_cast_inet(text)
    """)
  end
end
