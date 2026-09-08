defmodule Portal.Repo.Migrations.AddMCPFeature do
  use Ecto.Migration

  def up do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('mcp', false) ON CONFLICT (feature) DO UPDATE SET enabled = false"
    )

    execute(
      "DELETE FROM features WHERE feature IN ('mcp_identity_management', 'mcp_credential_issuance')"
    )
  end

  def down do
    execute("DELETE FROM features WHERE feature = 'mcp'")
  end
end
