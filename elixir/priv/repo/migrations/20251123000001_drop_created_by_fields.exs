defmodule Portal.Repo.Migrations.DropCreatedByFields do
  use Ecto.Migration

  def change do
    # List of tables that actually have created_by and created_by_subject fields
    tables_with_created_by = [
      :actor_groups,
      :actors,
      :email_otp_auth_providers,
      :entra_auth_providers,
      :entra_directories,
      :external_identities,
      :gateway_groups,
      :google_auth_providers,
      :google_directories,
      :oidc_auth_providers,
      :okta_auth_providers,
      :okta_directories,
      :policies,
      :relay_groups,
      :resource_connections,
      :resources,
      :tokens,
      :userpass_auth_providers
    ]

    # Drop the columns from each table
    Enum.each(tables_with_created_by, fn table ->
      alter table(table) do
        remove(:created_by)
        remove(:created_by_subject)
      end
    end)

    # Drop verified_by fields from clients table
    alter table(:clients) do
      remove(:verified_by)
      remove(:verified_by_subject)
    end

    # Drop created_by fields from tokens table
    alter table(:tokens) do
      remove(:created_by_user_agent)
      remove(:created_by_remote_ip)
    end
  end
end
