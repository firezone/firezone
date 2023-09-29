defmodule Domain.Repo.Migrations.UpdateClientsUpstreamDnsColumnType do
  use Ecto.Migration

  # def change do
  #  alter table("configurations") do
  #    modify(:clients_upstream_dns, {:array, :map},
  #      from: {:array, :string},
  #      default: [],
  #      null: false
  #    )
  #  end
  # end

  @drop_column "ALTER TABLE configurations DROP COLUMN clients_upstream_dns;"

  def change do
    execute(@drop_column)

    alter table("configurations") do
      add(:clients_upstream_dns, {:array, :map}, default: [], null: false)
    end
  end
end
