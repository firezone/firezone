defmodule Domain.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  def change do
    create table(:gateways, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:external_id, :string, null: false)

      add(:name_suffix, :string, null: false)

      add(:public_key, :string, null: false)

      add(:ipv4, references(:network_addresses, column: :address, type: :inet, match: :full))
      add(:ipv6, references(:network_addresses, column: :address, type: :inet, match: :full))

      add(:last_seen_user_agent, :string, null: false)
      add(:last_seen_remote_ip, :inet, null: false)
      add(:last_seen_version, :string, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)

      add(:token_id, references(:gateway_tokens, type: :binary_id), null: false)
      add(:group_id, references(:gateway_groups, type: :binary_id), null: false)

      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # Used for upserts
    # XXX: Should be per account in future.
    create(index(:gateways, [:group_id, :external_id], unique: true, where: "deleted_at IS NULL"))

    # Used to enforce unique IPv4 and IPv6 addresses.
    # XXX: Should be per account in future.
    create(index(:gateways, [:ipv4], unique: true, where: "deleted_at IS NULL"))
    create(index(:gateways, [:ipv6], unique: true, where: "deleted_at IS NULL"))

    # Used to enforce unique names and public keys.
    # XXX: Should be per account in future.
    create(index(:gateways, [:group_id, :name_suffix], unique: true, where: "deleted_at IS NULL"))
    create(index(:gateways, [:public_key], unique: true, where: "deleted_at IS NULL"))
  end
end
