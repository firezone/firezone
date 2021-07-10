defmodule FzHttp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string
      add :confirmed_at, :utc_datetime_usec
      add :password_hash, :string
      add :last_signed_in_at, :utc_datetime_usec
      add :reset_token, :string
      add :sign_in_token, :string
      add :sign_in_token_created_at, :utc_datetime_usec
      add :reset_sent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create index(:users, [:sign_in_token, :sign_in_token_created_at])
    create index(:users, [:reset_token, :reset_sent_at])
    create index(:users, [:confirmed_at])
  end
end
