defmodule Portal.Repo.Migrations.CopyClientTokens do
  use Ecto.Migration

  # Copies the client tokens written before the previous deploy, and by nodes
  # still on the version before it during its rollout. Deletes need no sync:
  # each copy's foreign key to its client token cascades.
  def up do
    execute("""
    INSERT INTO device_tokens (
      account_id, id, client_token_id, actor_id, auth_provider_id,
      secret_salt, secret_hash, expires_at, inserted_at, updated_at
    )
    SELECT
      ct.account_id, ct.id, ct.id, ct.actor_id, ct.auth_provider_id,
      ct.secret_salt, ct.secret_hash, ct.expires_at, ct.inserted_at, ct.updated_at
    FROM client_tokens AS ct
    ON CONFLICT DO NOTHING
    """)
  end

  # Rows written by the app since the copy are indistinguishable from it.
  def down, do: :ok
end
