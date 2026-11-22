defmodule Portal.Repo.Migrations.PointPolicyAuthorizationsTokenAtDeviceTokens do
  use Ecto.Migration

  # Client tokens are now written only to device_tokens. Every client token
  # already has a copy there, so the new key is added NOT VALID and validated
  # in the next deploy. A short lock_timeout keeps a blocked migration from
  # stalling authorizations.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE policy_authorizations
      DROP CONSTRAINT policy_authorizations_token_id_fkey,
      ADD CONSTRAINT policy_authorizations_token_id_fkey
        FOREIGN KEY (account_id, token_id)
        REFERENCES device_tokens (account_id, id)
        ON DELETE CASCADE
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    execute("""
    ALTER TABLE policy_authorizations
      DROP CONSTRAINT policy_authorizations_token_id_fkey,
      ADD CONSTRAINT policy_authorizations_token_id_fkey
        FOREIGN KEY (account_id, token_id)
        REFERENCES client_tokens (account_id, id)
        ON DELETE CASCADE
        NOT VALID
    """)
  end
end
