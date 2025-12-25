defmodule Portal.Repo.Migrations.RemoveOIDCConnections do
  use Ecto.Migration

  def change do
    drop(table(:oidc_connections))
  end
end
