defmodule Portal.Repo.Migrations.RemoveMCPFeature do
  use Ecto.Migration

  def up do
    execute("DELETE FROM features WHERE feature = 'mcp'")
  end

  def down do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('mcp', true) ON CONFLICT (feature) DO UPDATE SET enabled = true"
    )
  end
end
