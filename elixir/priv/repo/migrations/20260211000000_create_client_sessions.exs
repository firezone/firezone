defmodule Portal.Repo.Migrations.CreateClientSessions do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    # Make clients' last_seen_* fields nullable to make the deploy smoother
    alter table(:clients) do
      modify(:last_seen_user_agent, :string, null: true, from: {:string, null: false})
      modify(:last_seen_remote_ip, :inet, null: true, from: {:inet, null: false})
      modify(:last_seen_version, :string, null: true, from: {:string, null: false})

      modify(:last_seen_at, :utc_datetime_usec,
        null: true,
        from: {:utc_datetime_usec, null: false}
      )

      # Make clients.public_key nullable (it now lives on client_sessions)
      modify(:public_key, :string, null: true, from: {:string, null: false})
    end

    # client_tokens' last_seen_* fields are already nullable, so no need to modify them here

    # Drop the unique index on (actor_id, public_key) since public_key is moving
    execute(
      "DROP INDEX IF EXISTS clients_account_id_actor_id_public_key_index",
      """
      CREATE UNIQUE INDEX CONCURRENTLY clients_account_id_actor_id_public_key_index
      ON clients (account_id, actor_id, public_key)
      """
    )

    create table(:client_sessions, primary_key: false) do
      add(:account_id, :binary_id, primary_key: true, null: false)
      add(:id, :binary_id, primary_key: true, null: false)
      add(:client_id, :binary_id, null: false)
      add(:client_token_id, :binary_id, null: false)

      add(:public_key, :string)
      add(:user_agent, :string)
      add(:remote_ip, :inet)
      add(:remote_ip_location_region, :string)
      add(:remote_ip_location_city, :string)
      add(:remote_ip_location_lat, :float)
      add(:remote_ip_location_lon, :float)
      add(:version, :string)

      timestamps(updated_at: false)
    end

    execute(
      "ALTER TABLE client_sessions ADD CONSTRAINT client_sessions_account_id_fkey FOREIGN KEY (account_id) REFERENCES accounts(id)",
      "ALTER TABLE client_sessions DROP CONSTRAINT client_sessions_account_id_fkey"
    )

    execute(
      "ALTER TABLE client_sessions ADD CONSTRAINT client_sessions_client_id_fkey FOREIGN KEY (account_id, client_id) REFERENCES clients(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE client_sessions DROP CONSTRAINT client_sessions_client_id_fkey"
    )

    execute(
      "ALTER TABLE client_sessions ADD CONSTRAINT client_sessions_client_token_id_fkey FOREIGN KEY (account_id, client_token_id) REFERENCES client_tokens(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE client_sessions DROP CONSTRAINT client_sessions_client_token_id_fkey"
    )

    create(
      index(:client_sessions, [:client_id],
        name: :client_sessions_client_id_inserted_at_index,
        concurrently: true
      )
    )

    create(
      index(:client_sessions, [:inserted_at],
        name: :client_sessions_account_id_inserted_at_index,
        concurrently: true
      )
    )

    create(
      index(:client_sessions, [:client_token_id],
        name: :client_sessions_client_token_id_index,
        concurrently: true
      )
    )

    # Rename the account FK on client_tokens to match Ecto's default naming convention
    # (was missed in the earlier rename_fk_constraints migration)
    execute(
      "ALTER TABLE client_tokens RENAME CONSTRAINT tokens_account_id_fkey TO client_tokens_account_id_fkey",
      "ALTER TABLE client_tokens RENAME CONSTRAINT client_tokens_account_id_fkey TO tokens_account_id_fkey"
    )

    # Populate the client_sessions table with the data from clients and client_tokens
    execute(
      """
      INSERT INTO client_sessions (
        account_id, id, client_id, client_token_id,
        public_key,
        user_agent, remote_ip, remote_ip_location_region, remote_ip_location_city,
        remote_ip_location_lat, remote_ip_location_lon, version, inserted_at
      )
      SELECT
        c.account_id,
        gen_random_uuid(),
        c.id,
        t.id,
        c.public_key,
        c.last_seen_user_agent,
        c.last_seen_remote_ip,
        c.last_seen_remote_ip_location_region,
        c.last_seen_remote_ip_location_city,
        c.last_seen_remote_ip_location_lat,
        c.last_seen_remote_ip_location_lon,
        c.last_seen_version,
        COALESCE(c.last_seen_at, c.inserted_at)
      FROM clients c
      INNER JOIN LATERAL (
        SELECT t.id
        FROM client_tokens t
        WHERE t.actor_id = c.actor_id AND t.account_id = c.account_id
        ORDER BY t.updated_at DESC
        LIMIT 1
      ) t ON true
      WHERE c.last_seen_at IS NOT NULL
      """,
      "DELETE FROM client_sessions"
    )
  end
end
