defmodule FzHttp.Repo.Migrations.AddUserIdToRules do
  use Ecto.Migration

  def change do
    drop unique_index(:rules, [:destination, :action])

    alter table(:rules) do
      add :user_id, references(:users, on_delete: :delete_all), default: nil
    end

    create unique_index(:rules, [:user_id, :destination, :action])
  end
end
