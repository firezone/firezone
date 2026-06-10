defmodule Portal.Repo.Migrations.CreateApiRequestLogs do
  use Ecto.Migration

  def change do
    create table(:api_request_logs, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:event_id, :bytea, primary_key: true, null: false)

      # Intentionally no FKs: expired API tokens are hard-deleted every 5
      # minutes and actors can be deleted, but request history must survive.
      add(:actor_id, :binary_id, null: false)
      add(:api_token_id, :binary_id, null: false)

      add(:method, :string, null: false)
      add(:path, :text, null: false)
      add(:content_length, :bigint)

      # Plug.RequestId runs in the endpoint before the router, so every
      # logged request has one. remote_ip is the real client address: the
      # endpoint's RemoteIp plug resolves x-forwarded-for behind trusted
      # proxies onto conn.remote_ip before the router runs.
      add(:request_id, :string, null: false)

      add(:user_agent, :string)
      add(:remote_ip, :inet, null: false)
      add(:remote_ip_location_region, :string)
      add(:remote_ip_location_city, :string)
      add(:remote_ip_location_lat, :float)
      add(:remote_ip_location_lon, :float)

      add(:inserted_at, :timestamptz, null: false, default: fragment("now()"))
    end

    create(
      constraint(:api_request_logs, :event_id_is_12_bytes, check: "octet_length(event_id) = 12")
    )

    create(index(:api_request_logs, [:inserted_at]))
  end
end
