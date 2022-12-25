defmodule FzHttp.Repo.Migrations.FixSitesNullableFields do
  use Ecto.Migration

  def change do
    dns = System.get_env("WIREGUARD_DNS", "1.1.1.1,1.0.0.1")
    mtu = System.get_env("WIREGUARD_MTU", "1280")
    allowed_ips = System.get_env("WIREGUARD_ALLOWED_IPS", "0.0.0.0/0,::/0")
    persistent_keepalive = System.get_env("WIREGUARD_PERSISTENT_KEEPALIVE", "25")

    endpoint =
      System.get_env(
        "WIREGUARD_ENDPOINT",
        URI.parse(System.get_env("EXTERNAL_URL", "https://localhost/")).host
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
end
