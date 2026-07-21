defmodule Portal.Repo.Migrations.DropSessionTables do
  @moduledoc """
  Drops client_sessions and gateway_sessions after their latest-session data
  was collapsed onto devices (see CollapseDeviceSessions).

  Manual on purpose: run only after the release that stops reading and
  writing the session tables is fully rolled out, since old nodes still
  insert into them during the rollout.

  Rolling back recreates the empty tables; the dropped history is not
  recoverable (the latest row per device lives on in devices).
  """
  use Ecto.Migration

  def up do
    drop_if_exists(table(:client_sessions))
    drop_if_exists(table(:gateway_sessions))
  end

  def down do
    create_if_not_exists table(:client_sessions, primary_key: false) do
      add(:account_id, references(:accounts, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :uuid, null: false, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :device_id,
        references(:devices,
          type: :uuid,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :client_token_id,
        references(:client_tokens,
          type: :uuid,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false
      )

      add(:public_key, :string)
      add(:user_agent, :string)
      add(:remote_ip, :inet)
      add(:remote_ip_location_region, :string)
      add(:remote_ip_location_city, :string)
      add(:remote_ip_location_lat, :float)
      add(:remote_ip_location_lon, :float)
      add(:version, :string)
      add(:inserted_at, :timestamptz, null: false)
    end

    create_if_not_exists table(:gateway_sessions, primary_key: false) do
      add(:account_id, references(:accounts, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :uuid, null: false, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :device_id,
        references(:devices,
          type: :uuid,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :gateway_token_id,
        references(:gateway_tokens,
          type: :uuid,
          with: [account_id: :account_id],
          on_delete: :delete_all
        ),
        null: false
      )

      add(:public_key, :string, null: false)
      add(:user_agent, :string)
      add(:remote_ip, :inet)
      add(:remote_ip_location_region, :string)
      add(:remote_ip_location_city, :string)
      add(:remote_ip_location_lat, :float)
      add(:remote_ip_location_lon, :float)
      add(:version, :string)
      add(:inserted_at, :timestamptz, null: false)
    end

    create_if_not_exists(
      index(:client_sessions, [:account_id, :device_id, "inserted_at DESC"],
        name: :client_sessions_account_id_device_id_inserted_at_index
      )
    )

    create_if_not_exists(index(:client_sessions, [:inserted_at]))
    create_if_not_exists(index(:client_sessions, [:client_token_id]))

    create_if_not_exists(
      index(:gateway_sessions, [:account_id, :device_id, "inserted_at DESC"],
        name: :gateway_sessions_account_id_device_id_inserted_at_index
      )
    )

    create_if_not_exists(index(:gateway_sessions, [:inserted_at]))
    create_if_not_exists(index(:gateway_sessions, [:gateway_token_id]))
  end
end
