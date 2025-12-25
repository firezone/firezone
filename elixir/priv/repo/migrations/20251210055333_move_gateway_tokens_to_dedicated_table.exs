defmodule Portal.Repo.Migrations.MoveGatewayTokensToDedicatedTable do
  use Ecto.Migration

  def change do
    # Create the new gateway_tokens table
    create table(:gateway_tokens, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id), primary_key: true, null: false)
      add(:id, :uuid, primary_key: true)
      add(:site_id, :binary_id, null: false)
      add(:secret_salt, :string, null: false)
      add(:secret_hash, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Composite foreign key for (account_id, site_id) -> sites(account_id, id)
    execute(
      """
      ALTER TABLE gateway_tokens
      ADD CONSTRAINT gateway_tokens_site_id_fkey
      FOREIGN KEY (account_id, site_id) REFERENCES sites(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE gateway_tokens DROP CONSTRAINT gateway_tokens_site_id_fkey"
    )

    create(index(:gateway_tokens, [:site_id]))

    # Migrate existing site tokens from tokens table
    execute(
      """
      INSERT INTO gateway_tokens (account_id, id, site_id, secret_salt, secret_hash, inserted_at)
      SELECT account_id, id, site_id, secret_salt, secret_hash, inserted_at
      FROM tokens
      WHERE type = 'site'
      """,
      """
      INSERT INTO tokens (account_id, id, type, site_id, secret_salt, secret_hash, inserted_at, updated_at)
      SELECT account_id, id, 'site', site_id, secret_salt, secret_hash, inserted_at, inserted_at
      FROM gateway_tokens
      """
    )

    # Delete site tokens from the tokens table
    execute(
      "DELETE FROM tokens WHERE type = 'site'",
      "SELECT 1"
    )

    # Update the type constraint to remove 'site'
    drop(constraint(:tokens, :type_must_be_valid))

    create(
      constraint(:tokens, :type_must_be_valid,
        check: "type IN ('browser', 'client', 'api_client', 'email')"
      )
    )

    # Drop the site_id column from tokens table (also drops FK constraint and index)
    alter table(:tokens) do
      remove(:site_id, references(:sites, type: :binary_id))
    end
  end
end
