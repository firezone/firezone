defmodule Portal.Repo.Migrations.MakeAuthProvidersUnique do
  use Ecto.Migration

  def change do
    create(
      index(:auth_providers, [:account_id, :adapter],
        unique: true,
        where: "deleted_at IS NULL AND adapter in ('email', 'userpass', 'token')"
      )
    )

    execute("""
    CREATE UNIQUE INDEX auth_providers_account_id_oidc_adapter_index ON auth_providers (account_id, adapter, (adapter_config->>'client_id'))
    WHERE deleted_at IS NULL AND adapter = 'openid_connect';
    """)
  end
end
