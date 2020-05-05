defmodule CfHttp.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices) do
      add :name, :string
      add :verified_at, :utc_datetime
      add :public_key, :string
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps()
    end

    create index(:devices, [:user_id])
  end
end
