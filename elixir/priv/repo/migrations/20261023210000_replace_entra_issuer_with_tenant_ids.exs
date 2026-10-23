defmodule Portal.Repo.Migrations.ReplaceEntraIssuerWithTenantIds do
  use Ecto.Migration

  def up do
    alter table(:entra_auth_providers) do
      add :tenant_ids, {:array, :uuid}
    end

    # Only the already-configured tenant is trusted during migration. Stored
    # external identities do not establish an administrator's authorization.
    execute("""
    UPDATE entra_auth_providers
    SET tenant_ids = ARRAY[(regexp_match(issuer,
      '^https://login[.]microsoftonline[.]com/([0-9a-fA-F-]{36})/v2[.]0$'))[1]::uuid]
    """)

    alter table(:entra_auth_providers) do
      modify :tenant_ids, {:array, :uuid}, null: false
    end

    create constraint(:entra_auth_providers, :tenant_ids_must_not_be_empty,
      check: "cardinality(tenant_ids) > 0 AND array_position(tenant_ids, NULL) IS NULL"
    )

    drop index(:entra_auth_providers, [:account_id, :issuer],
      name: :entra_auth_providers_account_id_issuer_index
    )

    alter table(:entra_auth_providers) do
      remove :issuer
    end
  end

  def down do
    # A single issuer cannot represent an allowlist. Refuse a rollback that
    # would silently discard verified tenants or recreate duplicate providers.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM entra_auth_providers WHERE cardinality(tenant_ids) != 1) THEN
        RAISE EXCEPTION 'Cannot restore a single issuer while providers have multiple verified tenants';
      END IF;
    END $$
    """)

    alter table(:entra_auth_providers) do
      add :issuer, :text
    end

    execute("""
    UPDATE entra_auth_providers
    SET issuer = 'https://login.microsoftonline.com/' || tenant_ids[1]::text || '/v2.0'
    """)

    alter table(:entra_auth_providers) do
      modify :issuer, :text, null: false
    end

    create unique_index(:entra_auth_providers, [:account_id, :issuer],
      name: :entra_auth_providers_account_id_issuer_index
    )

    drop constraint(:entra_auth_providers, :tenant_ids_must_not_be_empty)

    alter table(:entra_auth_providers) do
      remove :tenant_ids
    end
  end
end
