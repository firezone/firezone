defmodule FzHttp.Repo.DataMigrations.MoveDefaultsToConfigurations do
  use Ecto.Migration

  def change do
    execute("""
    UPDATE configurations
    SET
      default_client_allowed_ips=#{val("allowed_ips", "0.0.0.0/0, ::/0")},
      default_client_dns=#{val("dns", "1.1.1.1, 1.0.0.1")},
      default_client_endpoint=#{val("endpoint", "NULL")},
      default_client_mtu=#{val("mtu", 1280)},
      default_client_persistent_keepalive=#{val("persistent_keepalive", 0)},
      default_client_port=#{val("port", 51820)},
      ipv4_enabled=#{val("ipv4_enabled", true)},
      ipv6_enabled=#{val("ipv6_enabled", true)},
      ipv4_network='#{val("ipv4_network", "10.3.2.0/24")}',
      ipv6_network='#{val("ipv6_network", "fd00::3:2:0/120")}',
      vpn_session_duration=COALESCE (subquery.vpn_session_duration, 0)
    FROM (
      SELECT
      allowed_ips,
      dns,
      endpoint,
      mtu,
      persistent_keepalive,
      vpn_session_duration
      FROM sites
    )
    AS subquery
    """)
  end

  defp val(key, default) do
    val = System.get_env("WIREGUARD_#{String.upcase(key)}") || default

    # These values may only be defined in the environment
    if key in [
         "port",
         "ipv4_enabled",
         "ipv6_enabled",
         "ipv4_network",
         "ipv6_network"
       ] do
      val
    else
      "COALESCE (subquery.#{key}, '#{val}')"
    end
  end
end
