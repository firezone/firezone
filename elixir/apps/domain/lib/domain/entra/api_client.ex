defmodule Domain.Entra.APIClient do
  @moduledoc """
  Client for Microsoft Graph API to verify Entra directory sync permissions.
  """

  @doc """
  Gets an access token using the OAuth2 client credentials flow.
  This verifies that the admin has granted the necessary permissions.
  """
  def get_access_token(tenant_id) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    client_id = config[:client_id]
    client_secret = config[:client_secret]
    token_base_url = config[:token_base_url]
    token_endpoint = "#{token_base_url}/#{tenant_id}/oauth2/v2.0/token"

    # Request access token to read what our app is set up to do (.default scope)
    scope = "https://graph.microsoft.com/.default"

    payload =
      URI.encode_query(%{
        "client_id" => client_id,
        "client_secret" => client_secret,
        "scope" => scope,
        "grant_type" => "client_credentials"
      })

    Req.post(token_endpoint,
      headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
      body: payload
    )
  end

  @doc """
  Gets the service principal for this application.
  This is needed to query appRoleAssignedTo for group assignment.
  """
  def get_service_principal(access_token, client_id) do
    query =
      URI.encode_query(%{
        "$filter" => "appId eq '#{client_id}'",
        "$select" => "id,appId"
      })

    get("/v1.0/servicePrincipals", query, access_token)
  end

  @doc """
  Lists assigned principals (users and groups) for the service principal.
  This respects group assignment settings in Entra.
  """
  def list_app_role_assignments(access_token, service_principal_id) do
    query =
      URI.encode_query(%{
        "$top" => "1",
        "$select" => "id,principalType,principalDisplayName"
      })

    get("/v1.0/servicePrincipals/#{service_principal_id}/appRoleAssignedTo", query, access_token)
  end

  @doc """
  Fetches users from Microsoft Graph API with a limit of 1.
  This is used to verify the Directory.Read.All permission is granted and working.
  """
  def list_users(access_token) do
    query =
      URI.encode_query(%{
        "$top" => "1",
        "$select" => "id,displayName"
      })

    get("/v1.0/users", query, access_token)
  end

  defp get(path, query, access_token) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    endpoint = config[:endpoint] || "https://graph.microsoft.com"

    url = "#{endpoint}#{path}?#{query}"
    Req.get(url, headers: [{"Authorization", "Bearer #{access_token}"}])
  end
end
