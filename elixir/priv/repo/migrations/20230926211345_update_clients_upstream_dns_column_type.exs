defmodule Portal.Repo.Migrations.UpdateClientsUpstreamDnsColumnType do
  use Ecto.Migration

  def change do
    execute("ALTER TABLE configurations DROP COLUMN clients_upstream_dns;")

    alter table("configurations") do
      add(:clients_upstream_dns, {:array, :map}, default: [], null: false)
    end
  end
end
