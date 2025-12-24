defmodule Portal.Repo.Migrations.RefactorClientsUpstreamDns do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      config,
      '{clients_upstream_dns}',
      CASE
        WHEN jsonb_array_length(config->'clients_upstream_dns') = 0 THEN
          '{"type": "system", "addresses": []}'::jsonb
        ELSE
          jsonb_build_object(
            'type', 'custom',
            'addresses', config->'clients_upstream_dns'
          )
      END
    )
    WHERE config->'clients_upstream_dns' IS NOT NULL
    AND jsonb_typeof(config->'clients_upstream_dns') = 'array'
    """)
  end

  def down do
    execute("""
    UPDATE accounts
    SET config = jsonb_set(
      config,
      '{clients_upstream_dns}',
      CASE
        WHEN config->'clients_upstream_dns'->>'type' = 'custom' THEN
          COALESCE(config->'clients_upstream_dns'->'addresses', '[]'::jsonb)
        ELSE
          '[]'::jsonb
      END
    )
    WHERE config->'clients_upstream_dns' IS NOT NULL
    AND jsonb_typeof(config->'clients_upstream_dns') = 'object'
    """)
  end
end
