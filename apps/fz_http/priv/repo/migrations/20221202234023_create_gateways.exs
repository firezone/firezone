defmodule FzHttp.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  def change do
    create table(:gateways, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:site_id, references(:sites, on_delete: :delete_all, type: :uuid), null: false)
      add(:ipv4_masquerade, :boolean, default: true, null: false)
      add(:ipv6_masquerade, :boolean, default: true, null: false)
      add(:ipv4_network, :cidr)
      add(:ipv6_network, :cidr)
      add(:wireguard_ipv4_address, :inet)
      add(:wireguard_ipv6_address, :inet)
      add(:wireguard_mtu, :integer, default: 1280, null: false)
      add(:wireguard_public_key, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:gateways, [:site_id]))
  end
end
