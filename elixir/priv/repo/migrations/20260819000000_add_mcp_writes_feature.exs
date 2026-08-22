defmodule Portal.Repo.Migrations.AddMcpWritesFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('mcp_writes', false) ON CONFLICT (feature) DO NOTHING",
      "DELETE FROM features WHERE feature = 'mcp_writes'"
    )
  end
end
