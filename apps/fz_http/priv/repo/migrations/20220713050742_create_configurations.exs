defmodule FzHttp.Repo.Migrations.CreateConfigurations do
  use Ecto.Migration

  def change do
    create table("configurations", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :logo, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index("configurations", [:name])

    now = DateTime.utc_now()

    execute("""
    INSERT INTO configurations (id, name, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'default', '#{now}', '#{now}')
    """)
  end
end
