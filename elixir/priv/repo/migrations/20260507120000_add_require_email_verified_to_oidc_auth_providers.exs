defmodule Portal.Repo.Migrations.AddRequireEmailVerifiedToOidcAuthProviders do
  use Ecto.Migration

  def up do
    alter table(:oidc_auth_providers) do
      add(:require_email_verified, :boolean, null: false, default: false)
    end

    alter table(:oidc_auth_providers) do
      modify(:require_email_verified, :boolean, null: false, default: true)
    end
  end

  def down do
    alter table(:oidc_auth_providers) do
      remove(:require_email_verified)
    end
  end
end
