defmodule FzHttp.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings) do
      add :key, :string
      add :value, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:settings, :key)

    flush()

    now = DateTime.utc_now()

    execute """
    INSERT INTO settings (key, value, inserted_at, updated_at) VALUES \
    ('default.device.dns_servers', '1.1.1.1, 1.0.0.1', '#{now}', '#{now}'),
    ('default.device.allowed_ips', '0.0.0.0/0, ::/0', '#{now}', '#{now}'),
    ('default.device.endpoint', null, '#{now}', '#{now}')
    """
  end
end
