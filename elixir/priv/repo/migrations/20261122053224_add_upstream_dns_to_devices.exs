defmodule Portal.Repo.Migrations.AddUpstreamDnsToDevices do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:upstream_dns, :map)
    end

    # Gateways keep using their own resolvers.
    execute("""
    UPDATE devices
    SET upstream_dns = '{"type": "system", "addresses": [], "doh_provider": "google"}'
    WHERE type = 'gateway' AND upstream_dns IS NULL
    """)
  end

  def down do
    alter table(:devices) do
      remove_if_exists(:upstream_dns, :map)
    end
  end
end
