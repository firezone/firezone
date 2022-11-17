defmodule FzHttp.Repo.Migrations.CreateRules do
  use Ecto.Migration

  @create_query "CREATE TYPE action_enum AS ENUM ('drop', 'accept')"
  @drop_query "DROP TYPE action_enum"

  def change do
    execute(@create_query, @drop_query)

    create table(:rules) do
      add(:destination, :inet, null: false)
      add(:action, :action_enum, default: "drop", null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:rules, [:destination, :action]))
  end
end
