defmodule FzHttp.Repo.Migrations.AddDefaultsToConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add(:default_client_allowed_ips, :text)
      add(:default_client_dns, :string)
      add(:default_client_endpoint, :string)
      add(:default_client_mtu, :integer)
      add(:default_client_persistent_keepalive, :integer)
      add(:default_client_port, :integer)
      add(:ipv4_enabled, :boolean)
      add(:ipv6_enabled, :boolean)
      add(:ipv4_network, :cidr)
      add(:ipv6_network, :cidr)
      add(:vpn_session_duration, :integer)
    end
  end
end
