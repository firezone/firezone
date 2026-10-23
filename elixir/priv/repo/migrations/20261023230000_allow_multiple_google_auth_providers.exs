defmodule Portal.Repo.Migrations.AllowMultipleGoogleAuthProviders do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS btree_gist")

    create constraint(:google_auth_providers, :google_workspace_domains_must_not_be_empty,
      check: """
      workspace_domains IS NULL OR (
        cardinality(workspace_domains) > 0
        AND array_position(workspace_domains, NULL) IS NULL
        AND array_position(workspace_domains, '') IS NULL
      )
      """
    )

    create unique_index(:google_auth_providers, [:account_id],
      where: "workspace_domains IS NULL",
      name: :google_auth_providers_account_id_unrestricted_index
    )

    # The exact set of normalized domains, rather than the interval between
    # their first and last values, must be disjoint within an account.
    execute("""
    CREATE TYPE google_workspace_domain_range AS RANGE (
      subtype = text,
      collation = "C",
      multirange_type_name = google_workspace_domain_multirange
    )
    """)

    execute("""
    CREATE FUNCTION google_workspace_domains_as_multirange(text[])
    RETURNS google_workspace_domain_multirange
    LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
    BEGIN ATOMIC
      SELECT range_agg(google_workspace_domain_range(lower(btrim(domain)), lower(btrim(domain)), '[]'))
      FROM unnest($1) AS domain;
    END
    """)

    create constraint(:google_auth_providers, :google_auth_providers_workspace_domains_excl,
      exclude: """
      gist (account_id WITH =, (google_workspace_domains_as_multirange(workspace_domains)) WITH &&)
      WHERE (workspace_domains IS NOT NULL)
      """
    )

    drop index(:google_auth_providers, [:account_id],
      name: :google_auth_providers_account_id_index
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM google_auth_providers GROUP BY account_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'Cannot restore a single Google provider per account while an account has multiple providers';
      END IF;
    END $$
    """)

    create unique_index(:google_auth_providers, [:account_id],
      name: :google_auth_providers_account_id_index
    )

    drop constraint(:google_auth_providers, :google_auth_providers_workspace_domains_excl)
    drop index(:google_auth_providers, [:account_id],
      name: :google_auth_providers_account_id_unrestricted_index
    )
    drop constraint(:google_auth_providers, :google_workspace_domains_must_not_be_empty)
    execute("DROP FUNCTION google_workspace_domains_as_multirange(text[])")
    execute("DROP TYPE google_workspace_domain_range")
  end
end
