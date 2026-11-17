defmodule Portal.Repo.Migrations.CascadeDeviceTokensActorFkey do
  use Ecto.Migration

  # Client tokens are deleted with their actor, as client_tokens does today.
  # The legacy Gateway actor cannot be deleted, so its tokens are not affected.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE device_tokens
      DROP CONSTRAINT device_tokens_actor_id_fkey,
      ADD CONSTRAINT device_tokens_actor_id_fkey
        FOREIGN KEY (actor_id, account_id)
        REFERENCES actors (id, account_id)
        ON DELETE CASCADE
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE device_tokens
      DROP CONSTRAINT device_tokens_actor_id_fkey,
      ADD CONSTRAINT device_tokens_actor_id_fkey
        FOREIGN KEY (actor_id, account_id)
        REFERENCES actors (id, account_id)
        NOT VALID
    """)
  end
end
