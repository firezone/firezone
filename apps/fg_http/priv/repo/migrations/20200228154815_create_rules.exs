defmodule FgHttp.Repo.Migrations.CreateBlacklistEntries do
  use Ecto.Migration

  def change do
    RuleActionEnum.create_type()

    create table(:rules) do
      add :destination, :inet, null: false
      add :action, RuleActionEnum.type(), default: "deny", null: false
      add :enabled, :boolean, default: true, null: false
      add :device_id, references(:devices, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:rules, [:device_id, :action])
    create index(:rules, [:enabled])
  end
end
