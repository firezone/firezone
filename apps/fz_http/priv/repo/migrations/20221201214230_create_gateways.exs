defmodule FzHttp.Repo.Migrations.CreateGateways do
  use Ecto.Migration

  @create_query "CREATE TYPE default_action_enum AS ENUM ('accept', 'deny')"
  @drop_query "DROP TYPE default_action_enum"

  def change do
    execute(@create_query, @drop_query)

    create table(:gateways, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:site_id, references(:sites, on_delete: :delete_all, type: :uuid), null: false)
      add(:ipv4_masquerade, :boolean, default: true, null: false)
      add(:ipv6_masquerade, :boolean, default: true, null: false)
      add(:ipv4_network, :cidr)
      add(:ipv6_network, :cidr)
      add(:wireguard_ipv4_address, :inet)
      add(:wireguard_ipv6_address, :inet)
      add(:wireguard_mtu, :integer)
      add(:wireguard_dns, :string)
      add(:wireguard_public_key, :string)
      add(:default_action, :default_action_enum, default: "deny", null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:gateways, [:site_id]))
  end
end
