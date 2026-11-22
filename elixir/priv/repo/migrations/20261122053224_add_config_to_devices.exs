defmodule Portal.Repo.Migrations.AddConfigToDevices do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    alter table(:devices) do
      add_if_not_exists(:config, :map)
    end

    # Gateways keep using their own resolvers and no search domain.
    execute("""
    UPDATE devices
    SET config = '{"clients_upstream_dns": {"type": "system", "addresses": [], "doh_provider": "google"}, "search_domain": null}'
    WHERE type = 'gateway' AND config IS NULL
    """)
  end

  def down do
    alter table(:devices) do
      remove_if_exists(:config, :map)
    end
  end
end
