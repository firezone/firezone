defmodule Portal.Repo.Migrations.CreatePortalSessions do
  use Ecto.Migration

  def change do
    create table(:portal_sessions, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id), primary_key: true, null: false)
      add(:id, :uuid, primary_key: true)
      add(:actor_id, :binary_id, null: false)
      add(:auth_provider_id, :binary_id, null: false)

      add(:user_agent, :string, size: 2000)
      add(:remote_ip, :inet)
      add(:remote_ip_location_region, :string)
      add(:remote_ip_location_city, :string)
      add(:remote_ip_location_lat, :float)
      add(:remote_ip_location_lon, :float)

      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Composite foreign key for (account_id, actor_id) -> actors(account_id, id)
    execute(
      """
      ALTER TABLE portal_sessions
      ADD CONSTRAINT portal_sessions_actor_id_fkey
      FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE portal_sessions DROP CONSTRAINT portal_sessions_actor_id_fkey"
    )

    # Composite foreign key for (account_id, auth_provider_id) -> auth_providers(account_id, id)
    execute(
      """
      ALTER TABLE portal_sessions
      ADD CONSTRAINT portal_sessions_auth_provider_id_fkey
      FOREIGN KEY (account_id, auth_provider_id) REFERENCES auth_providers(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE portal_sessions DROP CONSTRAINT portal_sessions_auth_provider_id_fkey"
    )

    create(index(:portal_sessions, [:actor_id]))
    create(index(:portal_sessions, [:auth_provider_id]))
    create(index(:portal_sessions, [:expires_at]))

    # Delete all browser tokens from the tokens table - these will be migrated to portal_sessions
    execute(
      "DELETE FROM tokens WHERE type = 'browser'",
      ""
    )

    # Update the type constraint to remove 'browser'
    drop(constraint(:tokens, :type_must_be_valid))

    create(constraint(:tokens, :type_must_be_valid, check: "type IN ('client', 'api_client')"))
  end
end
