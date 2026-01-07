defmodule Portal.Repo.Migrations.FixGlobalRelaysIndexes do
  use Ecto.Migration

  def change do
    execute("DROP INDEX relays_unique_addresses_idx")

    execute("""
    CREATE UNIQUE INDEX relays_unique_addresses_idx
    ON relays (account_id, COALESCE(ipv4, ipv6))
    WHERE deleted_at IS NULL AND account_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX global_relays_unique_addresses_idx
    ON relays (COALESCE(ipv4, ipv6))
    WHERE deleted_at IS NULL AND account_id IS NULL
    """)
  end
end
