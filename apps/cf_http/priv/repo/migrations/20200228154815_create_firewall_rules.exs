defmodule CfHttp.Repo.Migrations.CreateFirewallRules do
  use Ecto.Migration

  def change do
    create table(:firewall_rules) do
      add :destination, :inet
      add :port, :string
      add :protocol, :string
      add :enabled, :boolean, default: false, null: false
      add :device_id, references(:devices, on_delete: :delete_all)

      timestamps()
    end

    create index(:firewall_rules, [:device_id])
  end
end
