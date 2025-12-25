defmodule Portal.Repo.Migrations.MoveRelayTokensToDedicatedTable do
  use Ecto.Migration

  def change do
    # Create the new relay_tokens table
    create table(:relay_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:secret_salt, :string, null: false)
      add(:secret_hash, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Migrate existing relay tokens from tokens table
    execute(
      """
      INSERT INTO relay_tokens (id, secret_salt, secret_hash, inserted_at)
      SELECT id, secret_salt, secret_hash, inserted_at
      FROM tokens
      WHERE type = 'relay'
      """,
      """
      INSERT INTO tokens (id, type, secret_salt, secret_hash, inserted_at, updated_at)
      SELECT id, 'relay', secret_salt, secret_hash, inserted_at, inserted_at
      FROM relay_tokens
      """
    )

    # Delete relay tokens from the tokens table
    execute(
      "DELETE FROM tokens WHERE type = 'relay'",
      # No-op on rollback
      ""
    )

    # Update the type constraint to remove 'relay'
    drop(constraint(:tokens, :type_must_be_valid))

    create(
      constraint(:tokens, :type_must_be_valid,
        check: "type IN ('browser', 'client', 'api_client', 'site', 'email')"
      )
    )
  end
end
