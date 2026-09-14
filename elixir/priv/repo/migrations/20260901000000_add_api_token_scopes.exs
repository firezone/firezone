defmodule Portal.Repo.Migrations.AddApiTokenScopes do
  use Ecto.Migration

  def up do
    alter table(:api_tokens) do
      add(:scopes, {:array, :text})
    end

    # Existing tokens had unrestricted access, so they are backfilled rather
    # than left null. A backfilled token is pinned to today's vocabulary and
    # will not gain whatever scope is added next.
    execute("""
    UPDATE api_tokens
    SET scopes = ARRAY[
      'account:read',
      'actors:read',
      'actors:write',
      'groups:read',
      'groups:write',
      'external_identities:read',
      'external_identities:write',
      'clients:read',
      'clients:write',
      'client_tokens:read',
      'client_tokens:write',
      'sites:read',
      'sites:write',
      'gateways:read',
      'gateways:write',
      'gateway_tokens:write',
      'resources:read',
      'resources:write',
      'policies:read',
      'policies:write',
      'auth_providers:read',
      'directories:read',
      'posture_providers:read',
      'logs:read'
    ]::text[]
    """)

    alter table(:api_tokens) do
      modify(:scopes, {:array, :text}, null: false)
    end
  end

  def down do
    alter table(:api_tokens) do
      remove(:scopes)
    end
  end
end
