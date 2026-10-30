defmodule Portal.Repo.Migrations.HardenMCPActions do
  use Ecto.Migration

  def change do
    for feature <- ["mcp_identity_management", "mcp_credential_issuance"] do
      execute(
        "INSERT INTO features (feature, enabled) VALUES ('#{feature}', false) ON CONFLICT (feature) DO NOTHING",
        "DELETE FROM features WHERE feature = '#{feature}'"
      )
    end

    alter table(:api_request_logs) do
      add :mcp, :map
    end
  end
end
