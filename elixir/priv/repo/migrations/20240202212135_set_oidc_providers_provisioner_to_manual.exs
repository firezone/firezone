defmodule Portal.Repo.Migrations.SetOidcProvidersProvisionerToManual do
  use Ecto.Migration

  def change do
    execute("UPDATE auth_providers SET provisioner = 'manual' WHERE adapter = 'openid_connect'")
  end
end
