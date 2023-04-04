defmodule Domain.Repo.Migrations.MoveSitesFieldsToConfigurations do
  use Ecto.Migration

  @doc """
  XXX: The following env vars are used to configure interface settings
  on bootup and so we don't want to store them in the DB or update them
  at runtime. Leave them out of this migration.

  WIREGUARD_IPV4_ENABLED
  WIREGUARD_IPV6_ENABLED
  WIREGUARD_IPV4_NETWORK
  WIREGUARD_IPV6_NETWORK
  WIREGUARD_IPV4_ADDRESS
  WIREGUARD_IPV6_ADDRESS
  WIREGUARD_MTU
  """
  def change do
    alter table(:configurations) do
      add(:default_client_persistent_keepalive, :integer)
      add(:default_client_endpoint, :string)
      add(:default_client_dns, :string)
      add(:default_client_allowed_ips, :text)

      # XXX: Note this is different than the WIREGUARD_MTU env var which
      # configures the server interface MTU.
      add(:default_client_mtu, :integer)

      add(:vpn_session_duration, :integer, null: false, default: 0)
    end

    # persistent_keepalive
    execute("""
      UPDATE configurations
      SET default_client_persistent_keepalive = (
        SELECT persistent_keepalive
        FROM sites
        WHERE sites.name = 'default'
      )
    """)

    # endpoint
    execute("""
      UPDATE configurations
      SET default_client_endpoint = (
        SELECT endpoint
        FROM sites
        WHERE sites.name = 'default'
      )
    """)

    # dns
    execute("""
      UPDATE configurations
      SET default_client_dns = (
        SELECT dns
        FROM sites
        WHERE sites.name = 'default'
      )
    """)

    # allowed_ips
    execute("""
      UPDATE configurations
      SET default_client_allowed_ips = (
        SELECT allowed_ips
        FROM sites
        WHERE sites.name = 'default'
      )
    """)

    # mtu
    execute("""
      UPDATE configurations
      SET default_client_mtu = (
        SELECT mtu
        FROM sites
        WHERE sites.name = 'default'
      )
    """)

    # vpn_session_duration
    execute("""
      UPDATE configurations
      SET vpn_session_duration = (
        SELECT vpn_session_duration
        FROM sites
        WHERE sites.name = 'default'
      )
    """)
  end
end
