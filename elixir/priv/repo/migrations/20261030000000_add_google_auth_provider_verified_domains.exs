defmodule Portal.Repo.Migrations.AddGoogleAuthProviderVerifiedDomains do
  use Ecto.Migration

  def up do
    alter table(:google_auth_providers) do
      add :verified_domains, {:array, :text}
    end

    execute("""
    UPDATE google_auth_providers
    SET verified_domains = workspace_domains
    WHERE workspace_domains IS NOT NULL
    """)

    create constraint(:google_auth_providers, :google_enabled_domains_must_be_verified,
      check: """
      (verified_domains IS NULL AND workspace_domains IS NULL) OR (
        verified_domains IS NOT NULL
        AND workspace_domains IS NOT NULL
        AND cardinality(verified_domains) > 0
        AND array_position(verified_domains, NULL) IS NULL
        AND array_position(verified_domains, '') IS NULL
        AND workspace_domains <@ verified_domains
        AND verified_domains[1] = ANY(workspace_domains)
      )
      """
    )
  end

  def down do
    drop constraint(:google_auth_providers, :google_enabled_domains_must_be_verified)

    alter table(:google_auth_providers) do
      remove :verified_domains
    end
  end
end
