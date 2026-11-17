defmodule Portal.Repo.Migrations.PreserveLegacyGoogleSignIn do
  use Ecto.Migration

  def up do
    alter table(:google_auth_providers) do
      add :is_legacy_unrestricted, :boolean, null: false, default: false
    end

    # Preserve existing unrestricted providers. New providers default to
    # personal-only when they have no verified Workspace domains.
    execute("""
    UPDATE google_auth_providers
    SET is_legacy_unrestricted = true
    WHERE workspace_domains IS NULL
    """)

    create constraint(:google_auth_providers, :google_legacy_unrestricted_requires_no_domains,
      check: "NOT is_legacy_unrestricted OR workspace_domains IS NULL"
    )
  end

  def down do
    drop constraint(:google_auth_providers, :google_legacy_unrestricted_requires_no_domains)

    alter table(:google_auth_providers) do
      remove :is_legacy_unrestricted
    end
  end
end
