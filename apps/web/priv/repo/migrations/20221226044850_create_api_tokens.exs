defmodule Domain.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:expires_at, :timestamptz)

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      timestamps(updated_at: false)
    end

    create(index(:api_tokens, [:expires_at]))
    create(index(:api_tokens, [:user_id]))
  end
end
