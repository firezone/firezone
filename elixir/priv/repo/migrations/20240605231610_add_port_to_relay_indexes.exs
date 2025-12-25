defmodule Portal.Repo.Migrations.AddPortToRelayIndexes do
  use Ecto.Migration

  def change do
    execute("DROP INDEX relays_unique_address_index")
    execute("DROP INDEX global_relays_unique_address_index")

    execute("""
    CREATE UNIQUE INDEX relays_unique_address_index
    ON relays (account_id, COALESCE(ipv4, ipv6), port)
    WHERE deleted_at IS NULL AND account_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX global_relays_unique_address_index
    ON relays (COALESCE(ipv4, ipv6), port)
    WHERE deleted_at IS NULL AND account_id IS NULL
    """)
  end
end
