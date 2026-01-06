defmodule Portal.Repo.Migrations.CreateConfigurations do
  use Ecto.Migration

  def change do
    create table("configurations", primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:logo, :map)

      timestamps(type: :utc_datetime_usec)
    end

    now = DateTime.utc_now()

    execute("""
    INSERT INTO configurations (id, inserted_at, updated_at)
    VALUES (gen_random_uuid(), '#{now}', '#{now}')
    """)
  end
end
