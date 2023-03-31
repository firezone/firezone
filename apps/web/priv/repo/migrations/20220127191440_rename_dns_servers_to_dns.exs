defmodule FzHttp.Repo.Migrations.RenameDnsServersToDns do
  use Ecto.Migration

  def change do
    execute(
      """
      UPDATE settings
      SET key = 'default.device.dns'
      WHERE key = 'default.device.dns_servers'
      """,
      """
      UPDATE settings
      SET key = 'default.device.dns_servers'
      WHERE key = 'default.device.dns'
      """
    )

    rename(table(:devices), :dns_servers, to: :dns)
    rename(table(:devices), :use_default_dns_servers, to: :use_default_dns)
  end
end
