defmodule Domain.Repo.Migrations.AddDnsMutualExclusivityConstraint do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE accounts
    ADD CONSTRAINT dns_mutual_exclusivity CHECK (
      NOT (
        (config->'upstream_doh_provider' IS NOT NULL AND config->'upstream_doh_provider' != 'null'::jsonb)
        AND
        (jsonb_array_length(COALESCE(config->'upstream_do53', '[]'::jsonb)) > 0)
      )
    )
    """)
  end

  def down do
    execute("ALTER TABLE accounts DROP CONSTRAINT dns_mutual_exclusivity")
  end
end
