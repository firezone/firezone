defmodule Portal.Repo.Migrations.SimplifyAccountClientDNS do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      config,
      '{clients_upstream_dns}',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'address',
              CASE
                -- Strip port from IPv4 address (e.g., "1.1.1.1:53" -> "1.1.1.1")
                WHEN dns->>'address' ~ '^[0-9.]+:[0-9]+$' THEN
                  substring(dns->>'address' from '^([0-9.]+):[0-9]+$')
                -- Strip port from IPv6 address (e.g., "[::1]:53" -> "::1")
                WHEN dns->>'address' ~ '^\\\[.*\\\]:[0-9]+$' THEN
                  substring(dns->>'address' from '^\\\[(.+)\\\]:[0-9]+$')
                -- Address without port, use as-is
                ELSE
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
    AND jsonb_typeof(config->'clients_upstream_dns') = 'array'
    """)
  end

  def down do
  end
end
