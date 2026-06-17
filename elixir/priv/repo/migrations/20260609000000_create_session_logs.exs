defmodule Portal.Repo.Migrations.CreateSessionLogs do
  use Ecto.Migration

  def change do
    create table(:session_logs, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:event_id, :bytea, primary_key: true, null: false)
      add(:timestamp, :timestamptz, null: false)
      add(:lsn, :bigint, null: false)
      add(:context, :string, null: false)

      # Intentionally no FKs: actors, devices, tokens, and auth providers can
      # be deleted, but session history must survive them. actor_email is a
      # snapshot taken at session creation for the same reason.
      add(:actor_id, :binary_id)
      add(:actor_email, :string)
      add(:device_id, :binary_id)
      add(:token_id, :binary_id)
      add(:auth_provider_id, :binary_id)

      add(:user_agent, :string)
      add(:remote_ip, :inet)
      add(:remote_ip_location_region, :string)
      add(:remote_ip_location_city, :string)
      add(:remote_ip_location_lat, :float)
      add(:remote_ip_location_lon, :float)
    end

    create(constraint(:session_logs, :event_id_is_12_bytes, check: "octet_length(event_id) = 12"))

    create(
      constraint(:session_logs, :session_logs_context_chk,
        check: "context IN ('client', 'gateway', 'portal')"
      )
    )

    create(unique_index(:session_logs, [:lsn]))
    create(index(:session_logs, [:timestamp]))
  end
end
