defmodule FgHttp.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices) do
      add :name, :string, null: false
      add :public_key, :string, null: false
      add :ifname, :string, null: false
      add :last_ip, :inet
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:devices, [:user_id])
    create unique_index(:devices, [:public_key])
    create unique_index(:devices, [:name])
  end
end
