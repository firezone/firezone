defmodule Portal.Repo.Migrations.MoveApiTokensToDedicatedTable do
  use Ecto.Migration

  def change do
    # Create the new api_tokens table
    create table(:api_tokens, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:id, :uuid, primary_key: true)
      add(:actor_id, :binary_id, null: false)

      add(:name, :string, size: 255)

      add(:secret_salt, :string, null: false)
      add(:secret_hash, :string, null: false)

      add(:last_seen_user_agent, :string, size: 2000)
      add(:last_seen_remote_ip, :inet)
      add(:last_seen_remote_ip_location_region, :string)
      add(:last_seen_remote_ip_location_city, :string)
      add(:last_seen_remote_ip_location_lat, :float)
      add(:last_seen_remote_ip_location_lon, :float)
      add(:last_seen_at, :utc_datetime_usec)

      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps()
    end

    # Composite foreign key for (account_id, actor_id) -> actors(account_id, id)
    execute(
      """
      ALTER TABLE api_tokens
      ADD CONSTRAINT api_tokens_actor_id_fkey
      FOREIGN KEY (account_id, actor_id) REFERENCES actors(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE api_tokens DROP CONSTRAINT api_tokens_actor_id_fkey"
    )

    create(index(:api_tokens, [:actor_id]))
    create(index(:api_tokens, [:expires_at]))

    # Migrate existing api_client tokens from tokens table
    execute(
      """
      INSERT INTO api_tokens (
        account_id, id, actor_id, name, secret_salt, secret_hash,
        last_seen_user_agent, last_seen_remote_ip, last_seen_remote_ip_location_region,
        last_seen_remote_ip_location_city, last_seen_remote_ip_location_lat,
        last_seen_remote_ip_location_lon, last_seen_at, expires_at, inserted_at, updated_at
      )
      SELECT
        account_id, id, actor_id, name, secret_salt, secret_hash,
        last_seen_user_agent, last_seen_remote_ip, last_seen_remote_ip_location_region,
        last_seen_remote_ip_location_city, last_seen_remote_ip_location_lat,
        last_seen_remote_ip_location_lon, last_seen_at, expires_at, inserted_at, updated_at
      FROM tokens
      WHERE type = 'api_client'
      """,
      """
      INSERT INTO tokens (
        account_id, id, type, actor_id, name, secret_salt, secret_hash,
        last_seen_user_agent, last_seen_remote_ip, last_seen_remote_ip_location_region,
        last_seen_remote_ip_location_city, last_seen_remote_ip_location_lat,
        last_seen_remote_ip_location_lon, last_seen_at, expires_at, inserted_at, updated_at
      )
      SELECT
        account_id, id, 'api_client', actor_id, name, secret_salt, secret_hash,
        last_seen_user_agent, last_seen_remote_ip, last_seen_remote_ip_location_region,
        last_seen_remote_ip_location_city, last_seen_remote_ip_location_lat,
        last_seen_remote_ip_location_lon, last_seen_at, expires_at, inserted_at, updated_at
      FROM api_tokens
      """
    )

    # Delete api_client tokens from the tokens table
    execute(
      "DELETE FROM tokens WHERE type = 'api_client'",
      ""
    )

    # Update the type constraint to remove 'api_client'
    drop(constraint(:tokens, :type_must_be_valid))

    create(constraint(:tokens, :type_must_be_valid, check: "type IN ('client')"))
  end
end
