defmodule Portal.Repo.Migrations.AddExpiresAtToFlows do
  use Ecto.Migration

  def change do
    alter(table(:flows)) do
      add_if_not_exists(:expires_at, :utc_datetime_usec)
    end

    # Unfortunately cross-referencing any related token or policy expiration
    # to improve this is too complex to be considered worth it at this point in time.
    execute("""
      UPDATE flows
      SET expires_at = NOW() + INTERVAL '14 days'
    """)

    execute("""
      ALTER TABLE flows
      ALTER COLUMN expires_at SET NOT NULL
    """)
  end
end
