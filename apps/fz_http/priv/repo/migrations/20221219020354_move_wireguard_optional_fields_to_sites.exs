defmodule FzHttp.Repo.Migrations.MoveWireguardOptionalFieldsToSites do
  use Ecto.Migration

  def change do
    execute("""
      UPDATE sites
      SET dns = '#{System.get_env("WIREGUARD_DNS", "1.1.1.1,1.0.0.1")}'
      WHERE dns IS NULL
    """)

    execute("""
      UPDATE sites
      SET mtu = '#{System.get_env("WIREGUARD_MTU", "1280")}'
      WHERE mtu IS NULL
    """)

    execute("""
      UPDATE sites
      SET allowed_ips = '#{System.get_env("WIREGUARD_ALLOWED_IPS", "0.0.0.0/0,::/0")}'
      WHERE allowed_ips IS NULL
    """)

    execute("""
      UPDATE sites
      SET persistent_keepalive = '#{System.get_env("WIREGUARD_PERSISTENT_KEEPALIVE", "25")}'
      WHERE persistent_keepalive IS NULL
    """)

    execute("""
      UPDATE sites
      SET endpoint = '#{URI.parse(System.get_env("EXTERNAL_URL", "localhost")).host}'
      WHERE endpoint IS NULL
    """)
  end
end
