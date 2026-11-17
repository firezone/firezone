defmodule Portal.Repo.Migrations.AddSignInTenantIdToEntraAuthProviders do
  use Ecto.Migration

  def change do
    alter table(:entra_auth_providers) do
      add :sign_in_tenant_id, :uuid
    end

    create constraint(:entra_auth_providers, :sign_in_tenant_id_must_be_verified,
             check: "sign_in_tenant_id IS NULL OR sign_in_tenant_id = ANY(tenant_ids)"
           )
  end
end
