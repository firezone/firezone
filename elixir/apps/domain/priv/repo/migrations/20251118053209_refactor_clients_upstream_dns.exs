defmodule Domain.Repo.Migrations.RefactorClientsUpstreamDns do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      config,
      '{clients_upstream_dns}',
      CASE
        -- If clients_upstream_dns is an array (old structure)
        WHEN jsonb_typeof(config->'clients_upstream_dns') = 'array' THEN
          CASE
            -- If array is empty or null, default to system
            WHEN jsonb_array_length(COALESCE(config->'clients_upstream_dns', '[]'::jsonb)) = 0 THEN
              '{"type": "system", "addresses": []}'::jsonb
            -- If array has entries, convert to custom type with addresses
            ELSE
              jsonb_build_object(
                'type', 'custom',
                'addresses', (
                  SELECT jsonb_agg(
                    jsonb_build_object(
                      'address',
                      CASE
                        -- Strip port from ip_port protocol entries
                        WHEN dns->>'protocol' = 'ip_port' AND dns->>'address' ~ '^[0-9.]+:[0-9]+$' THEN
                          substring(dns->>'address' from '^([0-9.]+):[0-9]+$')
                        WHEN dns->>'protocol' = 'ip_port' AND dns->>'address' ~ '^\\\[.*\\\]:[0-9]+$' THEN
                          substring(dns->>'address' from '^\\\[(.+)\\\]:[0-9]+$')
                        ELSE
                          dns->>'address'
                      END
                    )
                  )
                  FROM jsonb_array_elements(config->'clients_upstream_dns') AS dns
                  WHERE dns->>'address' IS NOT NULL AND dns->>'address' != ''
                )
              )
          END
        -- If already an object or null, keep as-is (already migrated or default)
        WHEN jsonb_typeof(config->'clients_upstream_dns') = 'object' THEN
          config->'clients_upstream_dns'
        ELSE
          '{"type": "system", "addresses": []}'::jsonb
      END
    )
    WHERE config IS NOT NULL
    AND (
      config->'clients_upstream_dns' IS NULL
      OR jsonb_typeof(config->'clients_upstream_dns') = 'array'
    )
    """)
  end

  def down do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      config,
      '{clients_upstream_dns}',
      CASE
        -- If clients_upstream_dns is an object (new structure)
        WHEN jsonb_typeof(config->'clients_upstream_dns') = 'object' THEN
          CASE
            -- If type is custom, convert addresses back to array format
            WHEN config->'clients_upstream_dns'->>'type' = 'custom' THEN
              COALESCE(
                (
                  SELECT jsonb_agg(
                    jsonb_build_object(
                      'protocol', 'ip_port',
                      'address', addr->>'address' || ':53'
                    )
                  )
                  FROM jsonb_array_elements(config->'clients_upstream_dns'->'addresses') AS addr
                ),
                '[]'::jsonb
              )
            -- For system or DoH providers, return empty array
            ELSE
              '[]'::jsonb
          END
        -- If already an array, keep as-is
        WHEN jsonb_typeof(config->'clients_upstream_dns') = 'array' THEN
          config->'clients_upstream_dns'
        ELSE
          '[]'::jsonb
      END
    )
    WHERE config IS NOT NULL
    AND config->'clients_upstream_dns' IS NOT NULL
    AND jsonb_typeof(config->'clients_upstream_dns') = 'object'
    """)
  end
end
