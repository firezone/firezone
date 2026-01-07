defmodule Portal.Repo.Migrations.DisallowClientsGatewaysIpv4Ipv6Null do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      modify(:ipv4, :inet, null: false, from: {:inet, null: true})
      modify(:ipv6, :inet, null: false, from: {:inet, null: true})
    end

    alter table(:gateways) do
      modify(:ipv4, :inet, null: false, from: {:inet, null: true})
      modify(:ipv6, :inet, null: false, from: {:inet, null: true})
    end
  end
end
