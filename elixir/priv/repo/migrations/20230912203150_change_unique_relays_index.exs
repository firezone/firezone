defmodule Portal.Repo.Migrations.ChangeUniqueRelaysIndex do
  use Ecto.Migration

  def change do
    execute("DROP INDEX relays_unique_addresses_idx")
    execute("DROP INDEX global_relays_unique_addresses_idx")

    drop(
      index(:relays, [:account_id, :ipv4],
        unique: true,
        where: "deleted_at IS NULL AND ipv4 IS NOT NULL"
      )
    )

    drop(
      index(:relays, [:account_id, :ipv6],
        unique: true,
        where: "deleted_at IS NULL AND ipv6 IS NOT NULL"
      )
    )

    drop(
      index(:relays, [:ipv4],
        unique: true,
        name: :relays_ipv4_index,
        where: "account_id IS NULL AND deleted_at IS NULL AND ipv4 IS NOT NULL"
      )
    )

    drop(
      index(:relays, [:ipv6],
        unique: true,
        name: :relays_ipv6_index,
        where: "account_id IS NULL AND deleted_at IS NULL AND ipv6 IS NOT NULL"
      )
    )

    execute("""
    CREATE UNIQUE INDEX relays_unique_address_index
    ON relays (account_id, COALESCE(ipv4, ipv6))
    WHERE deleted_at IS NULL AND account_id IS NOT NULL
    """)

    execute("""
    CREATE UNIQUE INDEX global_relays_unique_address_index
    ON relays (COALESCE(ipv4, ipv6))
    WHERE deleted_at IS NULL AND account_id IS NULL
    """)
  end
end
