defmodule Portal.Repo.Migrations.AddMCPFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('mcp', false) ON CONFLICT (feature) DO NOTHING",
      "DELETE FROM features WHERE feature = 'mcp'"
    )
  end
end
