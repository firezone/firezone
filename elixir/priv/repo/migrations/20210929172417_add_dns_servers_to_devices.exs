defmodule Portal.Repo.Migrations.AddDnsServersToDevices do
  use Ecto.Migration

  @default_dns_servers "1.1.1.1, 1.0.0.1"

  def change do
    alter table(:devices) do
      add(:dns_servers, :string, default: @default_dns_servers)
    end
  end
end
