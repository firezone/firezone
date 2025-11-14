defmodule Domain.Repo.Migrations.SimplifyAccountClientDNS do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET config = config - 'clients_upstream_dns' || jsonb_build_object(
      'clients_upstream_dns',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'address',
              CASE
                WHEN dns->>'address' ~ '^[0-9.]+:[0-9]+$' THEN
                  -- IPv4 with port: strip the port
                  substring(dns->>'address' from '^([0-9.]+):[0-9]+$')
                WHEN dns->>'address' ~ '^\\\[.*\\\]:[0-9]+$' THEN
                  -- IPv6 with port in brackets: strip brackets and port
                  substring(dns->>'address' from '^\\\[(.+)\\\]:[0-9]+$')
                ELSE
                  -- No port or already just IP: use as-is
                  dns->>'address'
              END
            )
          )
          FROM jsonb_array_elements(config->'clients_upstream_dns') AS dns
          WHERE dns->>'address' IS NOT NULL AND dns->>'address' != ''
        ),
        '[]'::jsonb
      )
    )
    WHERE config->'clients_upstream_dns' IS NOT NULL
    """)
  end

  def down do
    execute("""
    UPDATE accounts
    SET config = config - 'clients_upstream_dns' || jsonb_build_object(
      'clients_upstream_dns',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'protocol', 'ip_port',
              'address', dns->>'address'
            )
          )
          FROM jsonb_array_elements(config->'clients_upstream_dns') AS dns
        ),
        '[]'::jsonb
      )
    )
    WHERE config->'clients_upstream_dns' IS NOT NULL
    """)
  end
end
