defmodule FgHttp.Repo.Migrations.CreateRules do
  use Ecto.Migration

  def change do
    RuleActionEnum.create_type()
    RuleProtocolEnum.create_type()

    create table(:rules) do
      add :destination, :inet
      add :protocol, RuleProtocolEnum.type(), default: "all", null: false
      add :action, RuleActionEnum.type(), default: "drop", null: false
      add :priority, :integer, default: 0, null: false
      add :enabled, :boolean, default: false, null: false
      add :port_number, :integer
      add :device_id, references(:devices, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:rules, [:device_id])
  end
end
