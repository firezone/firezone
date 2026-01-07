defmodule Portal.Repo.Migrations.AddTokens do
  use Ecto.Migration

  def change do
    create table(:tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:type, :string, null: false)
      add(:secret_salt, :string, null: false)
      add(:secret_hash, :string, null: false)

      add(
        :identity_id,
        references(:auth_identities, type: :binary_id, on_delete: :delete_all)
      )

      add(:created_by, :string, null: false)
      add(:created_by_identity_id, references(:auth_identities, type: :binary_id))
      add(:created_by_user_agent, :string, null: false)
      add(:created_by_remote_ip, :inet, null: false)

      add(:last_seen_at, :utc_datetime_usec)
      add(:last_seen_remote_ip, :inet)
      add(:last_seen_remote_ip_location_region, :text)
      add(:last_seen_remote_ip_location_city, :text)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
      add(:last_seen_user_agent, :string)
      add(:last_seen_version, :string)

      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:expires_at, :utc_datetime_usec, null: false)
      add(:deleted_at, :utc_datetime_usec)
      timestamps()
    end

    create(
      constraint(:tokens, :assoc_not_null,
        check: """
        (type = 'browser' AND identity_id IS NOT NULL)
        OR (type = 'client' AND identity_id IS NOT NULL)
        OR (type IN ('relay', 'gateway', 'email', 'api_client'))
        """
      )
    )

    create(index(:tokens, [:account_id, :type], where: "deleted_at IS NULL"))
  end
end
