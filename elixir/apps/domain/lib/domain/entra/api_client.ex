defmodule Domain.Entra.APIClient do
  @moduledoc """
  Client for Microsoft Graph API.
  """

  @doc """
  Gets an access token using the OAuth2 client credentials flow.
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
  Returns a single page with limit of 1 for verification purposes.
  """
  def list_app_role_assignments(access_token, service_principal_id) do
    query =
      URI.encode_query(%{
        "$top" => "1",
        "$select" => "id,principalId,principalType,principalDisplayName"
      })

    get("/v1.0/servicePrincipals/#{service_principal_id}/appRoleAssignedTo", query, access_token)
  end

  @doc """
  Streams assigned principals (users and groups) for the service principal.
  This respects group assignment settings in Entra.
  Returns a stream that yields pages of assignments.
  """
  def stream_app_role_assignments(access_token, service_principal_id) do
    query =
      URI.encode_query(%{
        "$top" => "999",
        "$select" => "id,principalId,principalType,principalDisplayName"
      })

    path = "/v1.0/servicePrincipals/#{service_principal_id}/appRoleAssignedTo"
    stream_pages(path, query, access_token)
  end

  @doc """
  Streams all groups from the directory.
  Returns a stream that yields pages of groups.
  """
  def stream_groups(access_token) do
    query =
      URI.encode_query(%{
        "$top" => "999",
        "$select" => "id,displayName"
      })

    path = "/v1.0/groups"
    stream_pages(path, query, access_token)
  end

  @doc """
  Streams transitive members of a group.
  Returns a stream that yields pages of members (users, groups, service principals).
  Fetches user profile fields that map to our identity schema.
  """
  def stream_group_transitive_members(access_token, group_id) do
    # Select only fields that we have in our identity schema:
    # id -> idp_id, displayName -> name, mail/userPrincipalName -> email,
    # givenName -> given_name, surname -> family_name, userPrincipalName -> preferred_username
    query =
      URI.encode_query(%{
        "$top" => "999",
        "$select" => "id,displayName,mail,userPrincipalName,givenName,surname,aboutMe"
      })

    path = "/v1.0/groups/#{group_id}/transitiveMembers"
    stream_pages(path, query, access_token)
  end

  @doc """
  Fetches multiple users by their IDs using JSON batching.
  Uses the $batch endpoint to get up to 20 users in a single HTTP request.
  Returns {:ok, users} where users is a list of user objects.
  """
  def batch_get_users(access_token, user_ids) when is_list(user_ids) do
    # Build batch request with individual GET requests for each user
    requests =
      user_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {user_id, index} ->
        %{
          id: Integer.to_string(index),
          method: "GET",
          url: "/users/#{user_id}?$select=id,displayName,mail,userPrincipalName,givenName,surname,aboutMe"
        }
      end)

    batch_body = %{requests: requests}

    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    endpoint = config[:endpoint] || "https://graph.microsoft.com"
    url = "#{endpoint}/v1.0/$batch"

    case Req.post(url,
           headers: [
             {"Authorization", "Bearer #{access_token}"},
             {"Content-Type", "application/json"}
           ],
           json: batch_body
         ) do
      {:ok, %Req.Response{status: 200, body: %{"responses" => responses}}} ->
        require Logger

        Logger.debug("Batch API response",
          response_count: length(responses),
          responses: inspect(responses, pretty: true, limit: :infinity)
        )

        # Extract successful user objects from batch responses
        users =
          responses
          |> Enum.filter(fn response ->
            status = response["status"]

            Logger.debug("Checking response status",
              status: inspect(status),
              match: status == 200
            )

            status == 200
          end)
          |> Enum.map(fn response -> response["body"] end)

        Logger.debug("Filtered users", count: length(users))

        {:ok, users}

      {:error, _} = error ->
        error
    end
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

  @doc """
  Fetches subscribed SKUs (licenses) for the organization.
  """
  def get_subscribed_skus(access_token) do
    get("/v1.0/subscribedSkus", "", access_token)
  end

  defp get(path, query, access_token) do
    config = Domain.Config.fetch_env!(:domain, __MODULE__)
    endpoint = config[:endpoint] || "https://graph.microsoft.com"

    url = "#{endpoint}#{path}?#{query}"
    Req.get(url, headers: [{"Authorization", "Bearer #{access_token}"}])
  end

  defp stream_pages(path, query, access_token) do
    Stream.resource(
      fn -> {path, query} end,
      fn
        nil ->
          {:halt, nil}

        {:error, _reason} = error ->
          # Halt stream on error
          {[error], nil}

        {current_path, current_query} ->
          case get(current_path, current_query, access_token) do
            {:ok, %Req.Response{status: 200, body: body}} ->
              # Use Map.fetch to ensure the "value" key exists
              # If the key is missing, it's an error condition (malformed response)
              case Map.fetch(body, "value") do
                {:ok, list} when is_list(list) ->
                  # Empty list is valid - it means no results for this page
                  # But the key must be present!
                  next_state =
                    case Map.get(body, "@odata.nextLink") do
                      nil ->
                        nil

                      next_link ->
                        uri = URI.parse(next_link)
                        next_path = String.replace(uri.path, "/v1.0", "")
                        next_query = uri.query || ""
                        {next_path, next_query}
                    end

                  {[list], next_state}

                {:ok, _non_list} ->
                  # Key exists but value is not a list - malformed response
                  error = {:error, {:invalid_response, "value is not a list", body}}
                  {[error], nil}

                :error ->
                  # Key is missing - this is an error! We must fail loudly to prevent false positives 
                  # that could delete groups/users if the API response format changes
                  error =
                    {:error, {:missing_key, "Expected key 'value' not found in response", body}}

                  {[error], nil}
              end

            {:ok, %Req.Response{} = response} ->
              # Non-200 response
              {[{:error, response}], nil}

            {:error, _reason} = error ->
              # Network or other error
              {[error], nil}
          end
      end,
      fn _ -> :ok end
    )
  end
end
