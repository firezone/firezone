defmodule CfPhx.Repo.Migrations.CreateFirewallRules do
  use Ecto.Migration

  def change do
    create table(:firewall_rules) do
      add :destination, :inet
      add :port, :string
      add :protocol, :string
      add :enabled, :boolean, default: false, null: false

      timestamps()
    end

  end
end
