defmodule FzHttp.Repo.Migrations.AddSamlIdentityProvidersToConfiguration do
  use Ecto.Migration

  def change do
    alter table(:configurations) do
      add :saml_identity_providers, :map
    end
  end
end
