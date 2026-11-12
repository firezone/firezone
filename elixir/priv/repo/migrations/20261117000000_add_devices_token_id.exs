defmodule Portal.Repo.Migrations.AddDevicesTokenId do
  use Ecto.Migration

  # Replaces client_token_id and gateway_token_id. The foreign key is added
  # NOT VALID and validated after the backfill.
  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:token_id, :binary_id)
    end

    execute("""
    ALTER TABLE devices
      ADD CONSTRAINT devices_token_id_fkey
        FOREIGN KEY (account_id, token_id)
        REFERENCES device_tokens (account_id, id)
        ON DELETE SET NULL (token_id)
        NOT VALID
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      remove_if_exists(:token_id, :binary_id)
    end
  end
end
