defmodule FgHttp.Repo.Migrations.CreatePasswordResets do
  use Ecto.Migration

  def change do
    create table(:password_resets) do
      add :reset_sent_at, :utc_datetime
      add :reset_token, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:password_resets, [:reset_token])
    create index(:password_resets, [:user_id])
  end
end
