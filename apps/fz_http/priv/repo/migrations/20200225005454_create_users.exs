defmodule FzHttp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string
      add :password_hash, :string
      add :last_signed_in_at, :utc_datetime_usec
      add :sign_in_token, :string
      add :sign_in_token_created_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create index(:users, [:sign_in_token, :sign_in_token_created_at])
  end
end
