defmodule FzHttp.Repo.Migrations.CreateDefaultGateway do
  use Ecto.Migration
  alias FzCommon.FzString

  @default_gateway_ipv4_address "10.3.2.1"
  @default_gateway_ipv6_address "fd00::3:2:1"

  def change do
    ipv4_masquerade = get_env("WIREGUARD_IPV4_MASQUERADE")
    ipv6_masquerade = get_env("WIREGUARD_IPV6_MASQUERADE")

    wireguard_ipv4_enabled = FzString.to_boolean(System.get_env("WIREGUARD_IPV4_ENABLED", "true"))
    wireguard_ipv6_enabled = FzString.to_boolean(System.get_env("WIREGUARD_IPV6_ENABLED", "true"))

    wireguard_ipv4_address =
      if wireguard_ipv4_enabled do
        add_single_quotes(System.get_env("WIREGUARD_IPV4_ADDRESS", @default_gateway_ipv4_address))
      else
        "NULL"
      end

    wireguard_ipv6_address =
      if wireguard_ipv6_enabled do
        add_single_quotes(System.get_env("WIREGUARD_IPV6_ADDRESS", @default_gateway_ipv6_address))
      else
        "NULL"
      end

    wireguard_mtu = get_env("WIREGUARD_MTU")
    registration_token = System.fetch_env!("GATEWAY_REGISTRATION_TOKEN")

    execute("""
      INSERT INTO gateways(name, ipv4_masquerade, ipv6_masquerade, ipv4_address, ipv6_address, mtu, registration_token, registration_token_created_at, inserted_at, updated_at) VALUES \
      ('default', #{ipv4_masquerade}, #{ipv6_masquerade}, #{wireguard_ipv4_address}, #{wireguard_ipv6_address}, #{wireguard_mtu}, '#{registration_token}', now(), now(), now())
    """)
  end

  defp add_single_quotes("DEFAULT"), do: "DEFAULT"
  defp add_single_quotes(val), do: "\'#{val}\'"

  defp get_env(env), do: System.get_env(env, "DEFAULT")
end
