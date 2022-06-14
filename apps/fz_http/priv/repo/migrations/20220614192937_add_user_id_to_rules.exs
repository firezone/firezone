defmodule FzHttp.Repo.Migrations.AddUserIdToRules do
  use Ecto.Migration

  def change do
    alter table(:rules) do
      add :user_id, references(:users, on_delete: :delete_all), default: nil
    end
  end
end
