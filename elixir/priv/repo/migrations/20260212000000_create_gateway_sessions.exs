defmodule Portal.Repo.Migrations.CreateGatewaySessions do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    # Make gateways' last_seen_* fields nullable to make the deploy smoother
    alter table(:gateways) do
      modify(:last_seen_user_agent, :string, null: true, from: {:string, null: true})
      modify(:last_seen_remote_ip, :inet, null: true, from: {:inet, null: true})
      modify(:last_seen_version, :string, null: true, from: {:string, null: true})

      modify(:last_seen_at, :utc_datetime_usec,
        null: true,
        from: {:utc_datetime_usec, null: true}
      )
    end

    create table(:gateway_sessions, primary_key: false) do
      add(:account_id, :binary_id, primary_key: true, null: false)
      add(:id, :binary_id, primary_key: true, null: false)
      add(:gateway_id, :binary_id, null: false)
      add(:gateway_token_id, :binary_id, null: false)

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
      "ALTER TABLE gateway_sessions ADD CONSTRAINT gateway_sessions_account_id_fkey FOREIGN KEY (account_id) REFERENCES accounts(id) ON DELETE CASCADE",
      "ALTER TABLE gateway_sessions DROP CONSTRAINT gateway_sessions_account_id_fkey"
    )

    execute(
      "ALTER TABLE gateway_sessions ADD CONSTRAINT gateway_sessions_gateway_id_fkey FOREIGN KEY (account_id, gateway_id) REFERENCES gateways(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE gateway_sessions DROP CONSTRAINT gateway_sessions_gateway_id_fkey"
    )

    execute(
      "ALTER TABLE gateway_sessions ADD CONSTRAINT gateway_sessions_gateway_token_id_fkey FOREIGN KEY (account_id, gateway_token_id) REFERENCES gateway_tokens(account_id, id) ON DELETE CASCADE",
      "ALTER TABLE gateway_sessions DROP CONSTRAINT gateway_sessions_gateway_token_id_fkey"
    )

    create(
      index(:gateway_sessions, [:gateway_id],
        name: :gateway_sessions_gateway_id_index,
        concurrently: true
      )
    )

    create(
      index(:gateway_sessions, [:inserted_at],
        name: :gateway_sessions_inserted_at_index,
        concurrently: true
      )
    )

    create(
      index(:gateway_sessions, [:gateway_token_id],
        name: :gateway_sessions_gateway_token_id_index,
        concurrently: true
      )
    )

    # Populate the gateway_sessions table with the data from gateways and gateway_tokens
    execute(
      """
      INSERT INTO gateway_sessions (
        account_id, id, gateway_id, gateway_token_id,
        user_agent, remote_ip, remote_ip_location_region, remote_ip_location_city,
        remote_ip_location_lat, remote_ip_location_lon, version, inserted_at
      )
      SELECT
        g.account_id,
        gen_random_uuid(),
        g.id,
        t.id,
        g.last_seen_user_agent,
        g.last_seen_remote_ip,
        g.last_seen_remote_ip_location_region,
        g.last_seen_remote_ip_location_city,
        g.last_seen_remote_ip_location_lat,
        g.last_seen_remote_ip_location_lon,
        g.last_seen_version,
        COALESCE(g.last_seen_at, g.inserted_at)
      FROM gateways g
      INNER JOIN LATERAL (
        SELECT t.id
        FROM gateway_tokens t
        WHERE t.site_id = g.site_id AND t.account_id = g.account_id
        ORDER BY t.inserted_at DESC
        LIMIT 1
      ) t ON true
      WHERE g.last_seen_at IS NOT NULL
      """,
      "DELETE FROM gateway_sessions"
    )
  end
end
