defmodule Domain.Repo.Migrations.CreateRelays do
  use Ecto.Migration

  def change do
    create table(:relays, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:ipv4, :inet)
      add(:ipv6, :inet)

      add(:last_seen_user_agent, :string, null: false)
      add(:last_seen_remote_ip, :inet, null: false)
      add(:last_seen_version, :string, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)

      add(:account_id, references(:accounts, type: :binary_id))
      add(:token_id, references(:relay_tokens, type: :binary_id), null: false)
      add(:group_id, references(:relay_groups, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    execute("""
    CREATE UNIQUE INDEX relays_unique_addresses_idx
    ON relays (account_id, COALESCE(ipv4, ipv6))
    WHERE deleted_at IS NULL
    """)

    # Used to enforce unique IPv4 and IPv6 addresses.
    create(
      index(:relays, [:account_id, :ipv4],
        unique: true,
        where: "deleted_at IS NULL AND ipv4 IS NOT NULL"
      )
    )

    create(
      index(:relays, [:account_id, :ipv6],
        unique: true,
        where: "deleted_at IS NULL AND ipv6 IS NOT NULL"
      )
    )
  end
end
