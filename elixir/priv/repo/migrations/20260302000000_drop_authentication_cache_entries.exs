defmodule Portal.Repo.Migrations.DropAuthenticationCacheEntries do
  use Ecto.Migration

  def change do
    drop_if_exists(table(:authentication_cache_entries))
  end
end
