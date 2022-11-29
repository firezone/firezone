defmodule FzHttp.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:revoked_at, :utc_datetime_usec)
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:api_tokens, [:revoked_at]))
    create(index(:api_tokens, [:user_id]))
  end
end
