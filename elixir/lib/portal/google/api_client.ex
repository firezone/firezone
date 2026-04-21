defmodule Portal.Google.APIClient do
  require Logger

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

    req_opts = config[:req_opts] || []

    Req.post(
      token_endpoint,
      [
        headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
        body: payload
      ] ++ req_opts
    )
  end

  def get_customer(access_token) do
    "/admin/directory/v1/customers/my_customer"
    |> get(access_token)
  end

  @doc """
  Fetches a single group by group key (Google group ID or email).

  Returns `{:ok, group_map}` on success, or `{:error, reason}` on failure.
  A 404 response returns `{:error, :not_found}`.
  """
  @spec get_group(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :forbidden | term()}
  def get_group(access_token, group_key) do
    case get("/admin/directory/v1/groups/#{URI.encode(group_key)}", access_token) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: 403}} -> {:error, :forbidden}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{} = response} -> {:error, response}
      {:error, _} = error -> error
    end
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
    req_opts = config[:req_opts] || []
    query = URI.encode_query(params)
    url = "#{config[:endpoint]}#{path}?#{query}"

    case Req.get(url, [headers: [Authorization: "Bearer #{access_token}"]] ++ req_opts) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> other
    end
  end

  @doc """
  Streams active users from the Google Workspace directory.
  Returns a stream that yields pages of users.
  """
  @active_user_query "isSuspended=false isArchived=false"

  def stream_users(access_token, domain) do
    query =
      URI.encode_query(%{
        "customer" => "my_customer",
        "domain" => domain,
        "maxResults" => "500",
        "projection" => "full",
        "query" => @active_user_query
      })

    path = "/admin/directory/v1/users"

    stream_pages(path, query, access_token, "users")
    |> Stream.map(&filter_active_google_users_result/1)
  end

  @doc """
  Streams groups from the Google Workspace directory.
  Returns a stream that yields pages of groups.

  ## Options

    * `:query` - optional query string passed directly to the API `query` parameter
      (e.g. `"email:firezone-sync*"` to filter by email prefix server-side)
  """
  def stream_groups(access_token, domain, opts \\ []) do
    params = %{
      "customer" => "my_customer",
      "domain" => domain,
      "maxResults" => "200"
    }

    params =
      case Keyword.get(opts, :query) do
        nil -> params
        q -> Map.put(params, "query", q)
      end

    path = "/admin/directory/v1/groups"
    stream_pages(path, URI.encode_query(params), access_token, "groups")
  end

  @doc """
  Streams members of a specific group.
  Returns a stream that yields pages of members.
  Fetches direct memberships only.
  """
  def stream_group_members(access_token, group_key) do
    query =
      URI.encode_query(%{
        "maxResults" => "200"
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

  # Google allows up to 1000 sub-requests per batch call. We use 100 to stay well
  # within limits and keep individual batch request sizes reasonable.
  @default_batch_endpoint "https://www.googleapis.com/batch/admin/directory/v1"
  @batch_size 100

  @doc """
  Fetches multiple users by Google user ID using the Google API Batch endpoint.

  Chunks `user_ids` into groups of #{@batch_size} and issues one multipart HTTP POST
  per chunk. Users that return 404 (deleted from Google Workspace) are silently
  skipped. Returns `{:ok, [user_map]}` or `{:error, reason}` on transport/HTTP failure.
  """
  @spec batch_get_users(String.t(), [String.t()]) :: {:ok, [map()]} | {:error, term()}
  def batch_get_users(_access_token, []), do: {:ok, []}

  def batch_get_users(access_token, user_ids) do
    result =
      user_ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc_chunks} ->
        case do_batch_get_users(access_token, chunk) do
          {:ok, users} -> {:cont, {:ok, [users | acc_chunks]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, chunks} ->
        {:ok, chunks |> Enum.reverse() |> List.flatten() |> Enum.filter(&active_google_user?/1)}

      {:error, _} = error ->
        error
    end
  end

  defp do_batch_get_users(access_token, user_ids) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_opts = config[:req_opts] || []
    batch_endpoint = config[:batch_endpoint] || @default_batch_endpoint
    boundary = "batch_#{System.unique_integer([:positive])}"

    body =
      user_ids
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {user_id, idx} ->
        "--#{boundary}\r\nContent-Type: application/http\r\nContent-ID: <item#{idx}@batch>\r\n\r\nGET /admin/directory/v1/users/#{URI.encode(user_id)}\r\n\r\n"
      end)
      |> Kernel.<>("--#{boundary}--")

    case Req.post(
           batch_endpoint,
           [
             headers: [
               {"Authorization", "Bearer #{access_token}"},
               {"Content-Type", "multipart/mixed; boundary=#{boundary}"}
             ],
             body: body
           ] ++ req_opts
         ) do
      {:ok, %Req.Response{status: 200, body: resp_body, headers: resp_headers}} ->
        content_type =
          resp_headers
          |> Map.get("content-type", [])
          |> List.first("")

        parse_batch_user_response(resp_body, content_type)

      {:ok, response} ->
        {:error, response}

      {:error, _} = error ->
        error
    end
  end

  defp parse_batch_user_response(body, content_type) do
    body = IO.iodata_to_binary(body)
    boundary = extract_multipart_boundary(content_type)

    body
    |> String.split("--#{boundary}")
    # Skip preamble (index 0) and the closing "--" delimiter (last element)
    |> Enum.slice(1..-2//1)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_batch_part(part) do
        {:ok, users} ->
          {:cont, {:ok, Enum.reverse(users, acc)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.reverse(users)}
      {:error, _} = error -> error
    end
  end

  defp extract_multipart_boundary(content_type) do
    case Regex.run(~r/boundary=(?:\"?([^\";\s,]+)\"?)/, content_type) do
      [_, boundary] when is_binary(boundary) and boundary != "" ->
        boundary

      _ ->
        raise "Could not extract multipart boundary from Content-Type: #{content_type}"
    end
  end

  defp parse_batch_part(part) do
    # Each part is:
    #   \r\n<outer headers>\r\n\r\n<nested HTTP response>
    # where <nested HTTP response> is:
    #   HTTP/1.1 200 OK\r\n<response headers>\r\n\r\n<JSON body>
    with [_outer_headers, nested] <- String.split(part, "\r\n\r\n", parts: 2),
         [status_and_headers, json_body] <- String.split(nested, "\r\n\r\n", parts: 2),
         status when status in [200, 404] <- extract_http_status(status_and_headers) do
      case status do
        404 ->
          {:ok, []}

        200 ->
          decode_json_user(json_body)
      end
    else
      status when is_integer(status) and status not in [200, 404] ->
        log_batch_parse_issue("Skipping batch users response part with unexpected status",
          status: status
        )

        normalized_status = normalize_status(status)

        {:error,
         %Req.Response{status: normalized_status, body: %{"error" => "Batch users part failed"}}}

      # Anything else (parse failure, unexpected status) — skip this part
      malformed ->
        log_batch_parse_issue("Skipping malformed batch users response part",
          detail: inspect(malformed),
          snippet: snippet(part)
        )

        {:error,
         %Req.Response{
           status: 502,
           body: %{"error" => "Malformed batch users response part"}
         }}
    end
  end

  defp decode_json_user(json_body) do
    case JSON.decode(String.trim(json_body)) do
      {:ok, user} ->
        {:ok, [user]}

      {:error, decode_error} ->
        log_batch_parse_issue(
          "Failed to decode JSON in batch users response part",
          error: inspect(decode_error),
          snippet: snippet(json_body)
        )

        {:error,
         %Req.Response{
           status: 502,
           body: %{"error" => "Invalid JSON in batch users response part"}
         }}
    end
  end

  defp normalize_status(status) when status > 0, do: status
  defp normalize_status(_status), do: 502

  defp log_batch_parse_issue(message, metadata) do
    Logger.warning(fn ->
      [
        message,
        " ",
        Enum.map_join(metadata, " ", fn {k, v} -> "#{k}=#{v}" end)
      ]
    end)
  end

  defp snippet(value, max_len \\ 160) do
    value = if is_binary(value), do: value, else: inspect(value)
    String.slice(value, 0, max_len)
  end

  defp extract_http_status(status_line_and_headers) do
    status_line =
      status_line_and_headers
      |> String.split("\r\n", parts: 2)
      |> List.first("")

    case Regex.run(~r/HTTP\/\d+\.\d+\s+(\d+)/, status_line) do
      [_, code] -> String.to_integer(code)
      _ -> 0
    end
  end

  @doc """
  Streams active users from a specific organization unit.
  Returns a stream that yields pages of users in the given org unit.
  """
  def stream_organization_unit_members(access_token, org_unit_path) do
    query =
      URI.encode_query(%{
        "customer" => "my_customer",
        "query" => "orgUnitPath='#{org_unit_path}' #{@active_user_query}",
        "maxResults" => "500",
        "projection" => "full"
      })

    path = "/admin/directory/v1/users"

    stream_pages(path, query, access_token, "users")
    |> Stream.map(&filter_org_unit_members_result/1)
  end

  defp filter_org_unit_members_result({:error, {:missing_key, _msg, _body}}), do: []
  defp filter_org_unit_members_result(result), do: filter_active_google_users_result(result)

  defp filter_active_google_users_result(users) when is_list(users) do
    Enum.filter(users, &active_google_user?/1)
  end

  defp filter_active_google_users_result(other), do: other

  defp active_google_user?(user) do
    case {Map.fetch(user, "suspended"), Map.fetch(user, "archived")} do
      {{:ok, suspended}, {:ok, archived}} ->
        suspended != true and archived != true

      _ ->
        Logger.error("Skipping Google user with missing suspended/archived flags",
          google_user_id: Map.get(user, "id", "unknown"),
          google_user_email: Map.get(user, "primaryEmail", Map.get(user, "email", "unknown"))
        )

        false
    end
  end

  defp get(path, access_token) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_opts = config[:req_opts] || []

    (config[:endpoint] <> path)
    |> Req.get([headers: [Authorization: "Bearer #{access_token}"]] ++ req_opts)
  end

  defp stream_pages(path, query, access_token, result_key) do
    Stream.resource(
      fn -> {path, query} end,
      fn
        nil ->
          {:halt, nil}

        {current_path, current_query} ->
          fetch_page(current_path, current_query, access_token, result_key)
      end,
      fn _ -> :ok end
    )
  end

  defp fetch_page(current_path, current_query, access_token, result_key) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_opts = config[:req_opts] || []
    url = "#{config[:endpoint]}#{current_path}?#{current_query}"

    case Req.get(url, [headers: [Authorization: "Bearer #{access_token}"]] ++ req_opts) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_page_response(body, current_path, current_query, result_key)

      {:ok, %Req.Response{} = response} ->
        {[{:error, response}], nil}

      {:error, _reason} = error ->
        {[error], nil}
    end
  end

  # Google's API omits these keys entirely when the collection is empty.
  # This includes `groups` when a filtered query (e.g. `email:firezone-sync*`) matches nothing.
  @optional_result_keys ~w[groups members organizationUnits]

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
