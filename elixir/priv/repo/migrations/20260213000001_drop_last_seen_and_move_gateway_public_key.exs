defmodule Portal.Repo.Migrations.DropLastSeenAndMoveGatewayPublicKey do
  use Ecto.Migration

  @last_seen_columns [
    :last_seen_user_agent,
    :last_seen_remote_ip,
    :last_seen_remote_ip_location_region,
    :last_seen_remote_ip_location_city,
    :last_seen_remote_ip_location_lat,
    :last_seen_remote_ip_location_lon,
    :last_seen_version,
    :last_seen_at
  ]

  def change do
    # Drop last_seen_* columns from clients, gateways, and client_tokens
    alter table(:clients) do
      for col <- @last_seen_columns do
        remove(col)
      end

      remove(:public_key)
    end

    alter table(:gateways) do
      for col <- @last_seen_columns do
        remove(col)
      end
    end

    alter table(:client_tokens) do
      for col <- @last_seen_columns do
        remove(col)
      end
    end

    # Add public_key to gateway_sessions and backfill from gateways
    alter table(:gateway_sessions) do
      add(:public_key, :string)
    end

    flush()

    execute("""
    UPDATE gateway_sessions gs
    SET public_key = g.public_key
    FROM gateways g
    WHERE gs.gateway_id = g.id
      AND gs.account_id = g.account_id
      AND g.public_key IS NOT NULL
    """)

    alter table(:gateway_sessions) do
      modify(:public_key, :string, null: false)
    end

    # Now drop public_key from gateways (also auto-drops gateways_account_id_public_key_index)
    alter table(:gateways) do
      remove(:public_key)
    end
  end
end
