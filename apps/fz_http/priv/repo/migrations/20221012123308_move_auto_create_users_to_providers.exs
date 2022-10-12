defmodule FzHttp.Repo.Migrations.MoveAutoCreateUsersToProviders do
  @moduledoc """
  I know this migration is hacky, but doing this in pure SQL is non-trivial
  for my level of Postgres-fu, so this will have to do.
  """
  use Ecto.Migration

  import Ecto.Query

  # Returns data like:
  # [
  #   %{
  #     openid_connect_providers: %{
  #       "new-provider-H2Ch" => %{
  #         "client_id" => "0oa3yiq0ahKwW2MhH5d7",
  #         "client_secret" => "3knL8CefL0RsoPVA6PukfoJxItdDz5a5Z8w6D618",
  #         "discovery_document_uri" => "https://okta-devok12.okta.com/.well-known/openid-configuration",
  #         "label" => "okta",
  #         "response_type" => "code",
  #         "scope" => "openid email profile"
  #       }
  #     }
  #   }
  # ]
  defp oid_provider_keys do
    FzHttp.Repo.all(from("configurations", select: [:openid_connect_providers]))
    # only one configuration at this point
    |> List.first()
    |> Map.get(:openid_connect_providers)
    |> Map.keys()
  end

  defp saml_provider_keys do
    FzHttp.Repo.all(from("configurations", select: [:saml_identity_providers]))
    # only one configuration at this point
    |> List.first()
    |> Map.get(:saml_identity_providers)
    |> Map.keys()
  end

  defp cur_oidc_create_users do
    FzHttp.Repo.all(from("configurations", select: [:auto_create_oidc_users]))
    |> List.first()
    |> Map.get(:auto_create_oidc_users)
  end

  def change do
    cur_oidc = cur_oidc_create_users() || System.get_env("AUTO_CREATE_OIDC_USERS", "true")

    for key <- oid_provider_keys() do
      execute """
      UPDATE configurations
      SET openid_connect_providers = jsonb_insert(
        (SELECT openid_connect_providers FROM configurations),
        '{#{key}, auto_create_users}', '#{cur_oidc}'
      ) WHERE 1 = 1;
      """
    end

    for key <- saml_provider_keys() do
      execute """
      UPDATE configurations
      SET saml_identity_providers = jsonb_insert(
        (SELECT saml_identity_providers FROM configurations),
        '{#{key}, auto_create_users}', 'true'
      ) WHERE 1 = 1;
      """
    end

    alter table(:configurations) do
      remove :auto_create_oidc_users
    end
  end
end
