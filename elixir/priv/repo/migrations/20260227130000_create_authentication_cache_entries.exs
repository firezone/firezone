defmodule Portal.Repo.Migrations.CreateAuthenticationCacheEntries do
  use Ecto.Migration

  def change do
    create table(:authentication_cache_entries, primary_key: false) do
      add(:key, :text, primary_key: true, null: false)
      add(:value, :map, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)

      timestamps(updated_at: false)
    end

    create(index(:authentication_cache_entries, [:expires_at]))
  end
end
