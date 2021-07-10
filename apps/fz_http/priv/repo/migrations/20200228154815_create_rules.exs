defmodule FzHttp.Repo.Migrations.CreateRules do
  use Ecto.Migration

  @create_query "CREATE TYPE action_enum AS ENUM ('deny', 'allow')"
  @drop_query "DROP TYPE action_enum"

  def change do
    execute(@create_query, @drop_query)

    create table(:rules) do
      add :destination, :inet, null: false
      add :action, :action_enum, default: "deny", null: false
      add :device_id, references(:devices, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:rules, [:device_id, :action])
    create unique_index(:rules, [:device_id, :destination, :action])
  end
end
