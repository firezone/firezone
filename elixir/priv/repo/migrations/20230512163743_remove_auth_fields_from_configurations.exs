defmodule Portal.Repo.Migrations.RemoveAuthFieldsFromConfigurations do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      remove(:openid_connect_providers)
      remove(:saml_identity_providers)
    end
  end
end
