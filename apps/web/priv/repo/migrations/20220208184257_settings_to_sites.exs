defmodule FzHttp.Repo.Migrations.SettingsToSites do
  use Ecto.Migration

  def change do
    create table(:sites, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :string)
      add(:dns, :string)
      add(:allowed_ips, :string)
      add(:endpoint, :string)
      add(:persistent_keepalive, :integer)
      add(:mtu, :integer)
      add(:vpn_session_duration, :integer)

      timestamps(type: :utc_datetime_usec)
    end

    now = DateTime.utc_now()

    execute("""
    INSERT INTO sites (id, name, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'default', '#{now}', '#{now}')
    """)

    execute("""
      UPDATE sites
      SET dns = (
        SELECT value
        FROM settings
        WHERE key = 'default.device.dns'
      )
      WHERE sites.name = 'default'
    """)

    execute("""
      UPDATE sites
      SET allowed_ips = (
        SELECT value
        FROM settings
        WHERE key = 'default.device.allowed_ips'
      )
      WHERE sites.name = 'default'
    """)

    execute("""
      UPDATE sites
      SET endpoint = (
        SELECT value
        FROM settings
        WHERE key = 'default.device.endpoint'
      )
      WHERE sites.name = 'default'
    """)

    execute("""
      UPDATE sites
      SET persistent_keepalive = (
        SELECT value::INTEGER
        FROM settings
        WHERE key = 'default.device.persistent_keepalive'
      )
      WHERE sites.name = 'default'
    """)

    execute("""
      UPDATE sites
      SET mtu = (
        SELECT value::INTEGER
        FROM settings
        WHERE key = 'default.device.mtu'
      )
      WHERE sites.name = 'default'
    """)

    execute("""
      UPDATE sites
      SET vpn_session_duration = (
        SELECT value::INTEGER
        FROM settings
        WHERE key = 'security.require_auth_for_vpn_frequency'
      )
      WHERE sites.name = 'default'
    """)

    drop(table(:settings))

    create(unique_index(:sites, :name))
  end
end
