defmodule Domain.Repo.Migrations.AddRequireAuthForVpnSetting do
  use Ecto.Migration

  @setting_key "security.require_auth_for_vpn_frequency"

  def change do
    now = DateTime.utc_now()

    up_sql = """
    INSERT INTO settings (key, value, inserted_at, updated_at) VALUES \
    ('#{@setting_key}', '0', '#{now}', '#{now}')
    """

    down_sql = """
    DELETE FROM settings WHERE key = '#{@setting_key}'
    """

    execute(up_sql, down_sql)
  end
end
