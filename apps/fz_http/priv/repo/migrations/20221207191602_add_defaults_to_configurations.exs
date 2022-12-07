defmodule FzHttp.Repo.Migrations.AddDefaultsToConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      modify(:id, :uuid, default: fragment("gen_random_uuid()"))
      add(:default_client_mtu, :integer, null: false, default: 1280)
      add(:default_client_persistent_keepalive, :integer, null: false, default: 0)
      add(:default_client_allowed_ips, :string, null: false, default: "0.0.0.0/0, ::/0")
      add(:default_client_dns, :string, null: false, default: "1.1.1.1, 1.0.0.1")
      # set by connectivity check
      add(:default_client_endpoint, :string, default: nil)
      add(:ipv4_enabled, :boolean, null: false, default: true)
      add(:ipv6_enabled, :boolean, null: false, default: true)
      add(:ipv4_network, :cidr, null: false, default: fragment("'10.3.2.0/24'::cidr"))
      add(:ipv6_network, :cidr, null: false, default: fragment("'fd00::3:2:0/120'::cidr"))
      add(:vpn_session_duration, :integer, null: false, default: 0)
    end
  end
end
