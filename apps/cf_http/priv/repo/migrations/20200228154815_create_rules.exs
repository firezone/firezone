defmodule CfHttp.Repo.Migrations.CreateRules do
  use Ecto.Migration

  def change do
    create table(:rules) do
      add :destination, :inet
      add :port, :string
      add :protocol, :string
      add :enabled, :boolean, default: false, null: false
      add :device_id, references(:devices, on_delete: :delete_all)

      timestamps()
    end

    create index(:rules, [:device_id])
  end
end
