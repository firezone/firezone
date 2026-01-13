defmodule Portal.Google.APIClient do
  def get_access_token(impersonation_email, key) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    token_endpoint = config[:token_endpoint]
    iss = key["client_email"]
    private_key = key["private_key"]

    unix_timestamp = :os.system_time(:seconds)
    jws = %{"alg" => "RS256", "typ" => "JWT"}
    jwk = JOSE.JWK.from_pem(private_key)

    scope = ~w[
      https://www.googleapis.com/auth/admin.directory.customer.readonly
      https://www.googleapis.com/auth/admin.directory.orgunit.readonly
      https://www.googleapis.com/auth/admin.directory.group.readonly
      https://www.googleapis.com/auth/admin.directory.user.readonly
    ] |> Enum.join(" ")

    claim_set =
      %{
        "iss" => iss,
        "scope" => scope,
        "aud" => token_endpoint,
        "sub" => impersonation_email,
        "exp" => unix_timestamp + 3600,
        "iat" => unix_timestamp
      }
      |> JSON.encode!()

    jwt =
      JOSE.JWS.sign(jwk, claim_set, jws)
      |> JOSE.JWS.compact()
      |> elem(1)

    payload =
      URI.encode_query(%{
        "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion" => jwt
      })

    req_options = config[:req_options] || []

    Req.post(
      token_endpoint,
      [
        headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
        body: payload
      ] ++ req_options
    )
  end

  def get_customer(access_token) do
    "/admin/directory/v1/customers/my_customer"
    |> get(access_token)
  end

  @doc """
  Tests connection by verifying access to all required Google Workspace endpoints.

  Makes minimal API calls (maxResults=1) to verify the service account has
  proper permissions for users, groups, and organization units endpoints.
  """
  @spec test_connection(String.t(), String.t()) :: :ok | {:error, term()}
  def test_connection(access_token, domain) do
    with :ok <- test_users(access_token, domain),
         :ok <- test_groups(access_token, domain),
         :ok <- test_org_units(access_token) do
      :ok
    end
  end

  defp test_users(access_token, domain) do
    test_endpoint(
      "/admin/directory/v1/users",
      access_token,
      %{"customer" => "my_customer", "domain" => domain, "maxResults" => "1"}
    )
  end

  defp test_groups(access_token, domain) do
    test_endpoint(
      "/admin/directory/v1/groups",
      access_token,
      %{"customer" => "my_customer", "domain" => domain, "maxResults" => "1"}
    )
  end

  defp test_org_units(access_token) do
    test_endpoint(
      "/admin/directory/v1/customer/my_customer/orgunits",
      access_token,
      %{"type" => "all"}
    )
  end

  defp test_endpoint(path, access_token, params) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_options = config[:req_options] || []
    query = URI.encode_query(params)
    url = "#{config[:endpoint]}#{path}?#{query}"

    case Req.get(url, [headers: [Authorization: "Bearer #{access_token}"]] ++ req_options) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> other
    end
  end

  @doc """
  Streams users from the Google Workspace directory.
  Returns a stream that yields pages of users.
  """
  def stream_users(access_token, domain) do
    query =
      URI.encode_query(%{
        "customer" => "my_customer",
        "domain" => domain,
        "maxResults" => "500",
        "projection" => "full"
      })

    path = "/admin/directory/v1/users"
    stream_pages(path, query, access_token, "users")
  end

  @doc """
  Streams groups from the Google Workspace directory.
  Returns a stream that yields pages of groups.
  """
  def stream_groups(access_token, domain) do
    query =
      URI.encode_query(%{
        "customer" => "my_customer",
        "domain" => domain,
        "maxResults" => "200"
      })

    path = "/admin/directory/v1/groups"
    stream_pages(path, query, access_token, "groups")
  end

  @doc """
  Streams members of a specific group.
  Returns a stream that yields pages of members.
  Uses includeDerivedMembership to fetch transitive memberships.
  """
  def stream_group_members(access_token, group_key) do
    query =
      URI.encode_query(%{
        "maxResults" => "200",
        "includeDerivedMembership" => "true"
      })

    path = "/admin/directory/v1/groups/#{group_key}/members"
    stream_pages(path, query, access_token, "members")
  end

  @doc """
  Streams organization units from the Google Workspace directory.
  Returns a stream that yields pages of organization units.
  """
  def stream_organization_units(access_token) do
    query =
      URI.encode_query(%{
        "type" => "all"
      })

    path = "/admin/directory/v1/customer/my_customer/orgunits"
    stream_pages(path, query, access_token, "organizationUnits")
  end

  @doc """
  Streams users from a specific organization unit.
  Returns a stream that yields pages of users in the given org unit.
  """
  def stream_organization_unit_members(access_token, org_unit_path) do
    query =
      URI.encode_query(%{
        "customer" => "my_customer",
        "query" => "orgUnitPath='#{org_unit_path}'",
        "maxResults" => "500",
        "projection" => "full"
      })

    path = "/admin/directory/v1/users"

    stream_pages(path, query, access_token, "users")
    |> Stream.map(fn
      # Org Unit with no members
      {:error, {:missing_key, _msg, _body}} ->
        []

      other ->
        other
    end)
  end

  defp get(path, access_token) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_options = config[:req_options] || []

    (config[:endpoint] <> path)
    |> Req.get([headers: [Authorization: "Bearer #{access_token}"]] ++ req_options)
  end

  defp stream_pages(path, query, access_token, result_key) do
    Stream.resource(
      fn -> {path, query} end,
      fn
        nil ->
          {:halt, nil}

        {:error, _reason} = error ->
          {[error], nil}

        {current_path, current_query} ->
          fetch_page(current_path, current_query, access_token, result_key)
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_page(current_path, current_query, access_token, result_key) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_options = config[:req_options] || []
    url = "#{config[:endpoint]}#{current_path}?#{current_query}"

    case Req.get(url, [headers: [Authorization: "Bearer #{access_token}"]] ++ req_options) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_page_response(body, current_path, current_query, result_key)

      {:ok, %Req.Response{} = response} ->
        {[{:error, response}], nil}

      {:error, _reason} = error ->
        {[error], nil}
    end
  end

  # Google's API omits these keys entirely when the collection is empty
  @optional_result_keys ~w[members organizationUnits]

  defp parse_page_response(body, current_path, current_query, result_key) do
    case Map.fetch(body, result_key) do
      {:ok, list} when is_list(list) ->
        next_state =
          case Map.get(body, "nextPageToken") do
            nil ->
              nil

            next_token ->
              query_map = URI.decode_query(current_query)
              updated_query = Map.put(query_map, "pageToken", next_token)
              next_query = URI.encode_query(updated_query)
              {current_path, next_query}
          end

        {[list], next_state}

      {:ok, _non_list} ->
        # Key exists but value is not a list - malformed response
        error = {:error, {:invalid_response, "#{result_key} is not a list", body}}
        {[error], nil}

      :error when result_key in @optional_result_keys ->
        # Empty collection - Google omits the key entirely
        {[[]], nil}

      :error ->
        # Key is missing - this is an error! Google API sometimes returns 200 with missing data
        # We must fail loudly to prevent false positives that could delete groups/users
        error =
          {:error, {:missing_key, "Expected key '#{result_key}' not found in response", body}}

        {[error], nil}
    end
  end
end
