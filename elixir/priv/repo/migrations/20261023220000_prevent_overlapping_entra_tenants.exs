defmodule Portal.Repo.Migrations.PreventOverlappingEntraTenants do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

    # UUID arrays have no GiST overlap operator class. Represent each UUID as
    # the closed singleton range [id,id], then index their exact set union.
    # Do not use [min(ids),max(ids)]: that would also reserve unrelated tenants
    # between the endpoints. Array order and duplicate entries do not matter.
    execute("""
    CREATE TYPE entra_tenant_range AS RANGE (
      subtype = uuid,
      multirange_type_name = entra_tenant_multirange
    )
    """)

    execute("""
    CREATE FUNCTION entra_tenant_ids_as_multirange(uuid[])
    RETURNS entra_tenant_multirange
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    BEGIN ATOMIC
      SELECT range_agg(entra_tenant_range(tenant_id, tenant_id, '[]'))
      FROM unnest($1) AS tenant_id;
    END
    """)

    create constraint(:entra_auth_providers, :entra_auth_providers_tenant_ids_excl,
      exclude:
        "gist (account_id WITH =, (entra_tenant_ids_as_multirange(tenant_ids)) WITH &&)"
    )
  end

  def down do
    drop constraint(:entra_auth_providers, :entra_auth_providers_tenant_ids_excl)
    execute("DROP FUNCTION entra_tenant_ids_as_multirange(uuid[])")
    execute("DROP TYPE entra_tenant_range")
  end
end
