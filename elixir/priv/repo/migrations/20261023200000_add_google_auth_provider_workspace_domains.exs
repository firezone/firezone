defmodule Portal.Repo.Migrations.AddGoogleAuthProviderWorkspaceDomains do
  use Ecto.Migration

  def change do
    alter table(:google_auth_providers) do
      add :workspace_domains, {:array, :text}
    end
  end
end
