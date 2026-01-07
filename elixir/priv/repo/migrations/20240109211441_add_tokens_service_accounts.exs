defmodule Portal.Repo.Migrations.AddTokensServiceAccounts do
  use Ecto.Migration

  def change do
    execute("DELETE FROM tokens")

    alter table(:tokens) do
      add(:name, :string)

      add(
        :actor_id,
        references(:actors, type: :binary_id, on_delete: :delete_all)
      )
    end

    drop(
      constraint(:tokens, :assoc_not_null,
        check: """
        (type = 'browser' AND identity_id IS NOT NULL)
        OR (type = 'client' AND identity_id IS NOT NULL)
        OR (type IN ('relay', 'gateway', 'email', 'api_client'))
        """
      )
    )

    create(
      constraint(:tokens, :assoc_not_null,
        check: """
        (type = 'browser' AND identity_id IS NOT NULL)
        OR (type = 'client' AND (
          (identity_id IS NOT NULL AND actor_id IS NOT NULL)
          OR actor_id IS NOT NULL)
        )
        OR (type IN ('relay', 'gateway', 'email', 'api_client'))
        """
      )
    )

    execute("""
    DELETE FROM auth_identities WHERE provider_id IN (
      SELECT id FROM auth_providers WHERE adapter = 'token'
    )
    """)

    execute("DELETE FROM auth_providers WHERE adapter = 'token'")

    execute("ALTER TABLE clients ALTER COLUMN identity_id DROP NOT NULL")
  end
end
