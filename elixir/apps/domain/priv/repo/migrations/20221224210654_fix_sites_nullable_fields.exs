defmodule Domain.Repo.Migrations.FixSitesNullableFields do
  use Ecto.Migration

  require Logger

  def change do
    dns = System.get_env("WIREGUARD_DNS", "1.1.1.1,1.0.0.1")
    mtu = System.get_env("WIREGUARD_MTU", "1280")
    allowed_ips = System.get_env("WIREGUARD_ALLOWED_IPS", "0.0.0.0/0,::/0")
    persistent_keepalive = System.get_env("WIREGUARD_PERSISTENT_KEEPALIVE", "25")

    endpoint =
      System.get_env(
        "WIREGUARD_ENDPOINT",
        host()
      ) <> ":" <> System.get_env("WIREGUARD_PORT", "51820")

    execute("""
      UPDATE sites
      SET dns = '#{dns}'
      WHERE dns IS NULL
    """)

    execute("""
      UPDATE sites
      SET mtu = #{mtu}
      WHERE mtu IS NULL
    """)

    execute("""
      UPDATE sites
      SET allowed_ips = '#{allowed_ips}'
      WHERE allowed_ips IS NULL
    """)

    execute("""
      UPDATE sites
      SET persistent_keepalive = #{persistent_keepalive}
      WHERE persistent_keepalive IS NULL
    """)

    execute("""
      UPDATE sites
      SET endpoint = '#{endpoint}'
      WHERE endpoint IS NULL
    """)
  end

  defp host do
    external_url_var = System.get_env("EXTERNAL_URL")
    substitute = "https://localhost/"

    external_url =
      if is_nil(external_url_var) || String.length(external_url_var) == 0 do
        Logger.warning(
          "EXTERNAL_URL is empty! Using #{substitute} as basis for WireGuard endpoint."
        )

        substitute
      else
        external_url_var
      end

    parsed_host = URI.parse(external_url).host

    if is_nil(parsed_host) do
      Logger.warning(
        "EXTERNAL_URL doesn't seem to contain a valid URL. Assuming https://#{external_url}."
      )

      external_url
    else
      parsed_host
    end
  end
end
