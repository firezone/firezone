defmodule FgHttp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string
      add :confirmed_at, :utc_datetime
      add :password_hash, :string
      add :last_signed_in_at, :utc_datetime
      add :reset_sent_at, :utc_datetime
      add :reset_token, :utc_datetime

      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:reset_token])
  end
end
