defmodule Portal.Google.APIClient do
  require Logger

  alias Portal.TokenCache

  @jwt_bearer_grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @token_exchange_grant_type "urn:ietf:params:oauth:grant-type:token-exchange"
  @access_token_type "urn:ietf:params:oauth:token-type:access_token"
  @jwt_token_type "urn:ietf:params:oauth:token-type:jwt"
  @cloud_platform_scope "https://www.googleapis.com/auth/cloud-platform"
  @customer_readonly_scope "https://www.googleapis.com/auth/admin.directory.customer.readonly"
  @workspace_scope [
    @customer_readonly_scope,
    "https://www.googleapis.com/auth/admin.directory.orgunit.readonly",
    "https://www.googleapis.com/auth/admin.directory.group.readonly",
    "https://www.googleapis.com/auth/admin.directory.user.readonly"
  ]
                   |> Enum.join(" ")

  @federation_failure_stages [
    :managed_identity,
    :workload_identity_token_exchange,
    :service_account_sign_jwt
  ]
  @token_cache Portal.Google.TokenCache
  @max_retries 5

  @doc """
  Gets a delegated Google Workspace access token using deployment credentials.

  Workload identity federation is preferred when fully configured. A deployment
  service account key is used when federation is not configured and remains a
  temporary fallback for federation-stage failures until the key is removed.
  """
  def get_access_token(impersonation_email) do
    get_delegated_access_token(impersonation_email, @workspace_scope)
  end

  @doc """
  Gets a delegated access token limited to reading Workspace customer information.

  This is used to verify that an interactively authenticated Google user can read
  the customer record without granting Admin SDK scopes to the interactive OAuth
  client.
  """
  def get_customer_access_token(impersonation_email) do
    get_delegated_access_token(impersonation_email, @customer_readonly_scope)
  end

  defp get_delegated_access_token(impersonation_email, scope) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    case workload_identity_config(config) do
      {:ok, workload_identity_config} ->
        impersonation_email
        |> get_federated_access_token(scope, config, workload_identity_config)
        |> maybe_fallback_to_service_account_key(impersonation_email, scope, config)

      :not_configured ->
        get_access_token_with_configured_key(impersonation_email, scope, config)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Gets a delegated Google Workspace access token using a service account key.

  This path is retained for directories with a customer-specific legacy key.
  """
  def get_access_token(impersonation_email, key) when is_map(key) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    get_access_token_with_key(impersonation_email, key, @workspace_scope, config)
  end

  defp get_access_token_with_key(impersonation_email, key, scope, config) do
    cache_key = workspace_cache_key(impersonation_email, scope, {:service_account_key, key})

    TokenCache.fetch(token_cache(config), cache_key, fn ->
      fetch_key_access_token(impersonation_email, key, scope, config)
    end)
  end

  defp get_federated_access_token(
         impersonation_email,
         scope,
         config,
         workload_identity_config
       ) do
    federated_cache_key =
      {:federated_access_token, workload_identity_config.provider,
       workload_identity_config.audience}

    with {:ok, federated_token} <-
           TokenCache.fetch(token_cache(config), federated_cache_key, fn ->
             fetch_federated_token(workload_identity_config, config)
           end) do
      cache_key =
        workspace_cache_key(
          impersonation_email,
          scope,
          {:federated, workload_identity_config}
        )

      TokenCache.fetch(token_cache(config), cache_key, fn ->
        fetch_federated_access_token(
          impersonation_email,
          workload_identity_config.service_account_email,
          federated_token,
          scope,
          config
        )
      end)
    end
  end

  defp token_cache(config), do: Keyword.get(config, :token_cache, @token_cache)

  defp fetch_federated_token(workload_identity_config, config) do
    with {:ok, azure_token} <-
           managed_identity_token(workload_identity_config.audience) do
      exchange_azure_token(
        azure_token,
        workload_identity_config.provider,
        config
      )
    end
  end

  defp fetch_federated_access_token(
         impersonation_email,
         service_account_email,
         federated_token,
         scope,
         config
       ) do
    claims = claim_set(impersonation_email, service_account_email, scope, config[:token_endpoint])

    with {:ok, signed_jwt} <-
           sign_jwt(claims, service_account_email, federated_token, config) do
      signed_jwt
      |> exchange_signed_jwt(config)
      |> access_token_response()
    end
  end

  defp fetch_key_access_token(impersonation_email, key, scope, config) do
    jws = %{"alg" => "RS256", "typ" => "JWT"}
    jwk = JOSE.JWK.from_pem(key["private_key"])

    claim_set =
      impersonation_email
      |> claim_set(key["client_email"], scope, config[:token_endpoint])
      |> JSON.encode!()

    jwt =
      JOSE.JWS.sign(jwk, claim_set, jws)
      |> JOSE.JWS.compact()
      |> elem(1)

    jwt
    |> exchange_signed_jwt(config)
    |> access_token_response()
  end

  defp exchange_azure_token(azure_token, workload_identity_provider, config) do
    payload =
      URI.encode_query(%{
        "audience" => workload_identity_provider,
        "grant_type" => @token_exchange_grant_type,
        "requested_token_type" => @access_token_type,
        "scope" => @cloud_platform_scope,
        "subject_token" => azure_token,
        "subject_token_type" => @jwt_token_type
      })

    case Req.post(
           config[:sts_endpoint],
           [
             headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
             body: payload
           ] ++ request_opts(config)
         ) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"access_token" => access_token, "expires_in" => expires_in}
       }} ->
        {:ok, %{token: access_token, expires_in: expires_in}}

      {:ok, %Req.Response{} = response} ->
        {:error, {:workload_identity_token_exchange, response}}

      {:error, reason} ->
        {:error, {:workload_identity_token_exchange, reason}}
    end
  end

  defp managed_identity_token(audience) do
    {:ok, Portal.Azure.ManagedIdentity.access_token!(audience)}
  rescue
    exception -> {:error, {:managed_identity, exception}}
  end

  defp maybe_fallback_to_service_account_key(
         {:error, {stage, _reason}} = error,
         impersonation_email,
         scope,
         config
       )
       when stage in @federation_failure_stages do
    case config[:service_account_key] do
      key when is_binary(key) and key != "" ->
        Logger.warning("Google workload identity federation failed; using service account key",
          stage: stage
        )

        get_access_token_with_key(impersonation_email, JSON.decode!(key), scope, config)

      _ ->
        error
    end
  end

  defp maybe_fallback_to_service_account_key(
         result,
         _impersonation_email,
         _scope,
         _config
       ),
       do: result

  defp get_access_token_with_configured_key(impersonation_email, scope, config) do
    case config[:service_account_key] do
      key when is_binary(key) and key != "" ->
        get_access_token_with_key(impersonation_email, JSON.decode!(key), scope, config)

      _ ->
        {:error, :service_account_not_configured}
    end
  end

  defp workload_identity_config(config) do
    values = [
      config[:workload_identity_provider],
      config[:workload_identity_audience],
      config[:service_account_email]
    ]

    cond do
      Enum.all?(values, &blank?/1) ->
        :not_configured

      Enum.all?(values, &present?/1) ->
        {:ok,
         %{
           provider: config[:workload_identity_provider],
           audience: config[:workload_identity_audience],
           service_account_email: config[:service_account_email]
         }}

      true ->
        {:error, :incomplete_workload_identity_configuration}
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
  defp present?(value), do: is_binary(value) and value != ""

  defp sign_jwt(claims, service_account_email, access_token, config) do
    endpoint =
      "#{config[:iam_credentials_endpoint]}/v1/projects/-/serviceAccounts/" <>
        "#{URI.encode(service_account_email)}:signJwt"

    case Req.post(
           endpoint,
           [
             headers: [{"Authorization", "Bearer #{access_token}"}],
             json: %{"payload" => JSON.encode!(claims)}
           ] ++ request_opts(config)
         ) do
      {:ok, %Req.Response{status: 200, body: %{"signedJwt" => signed_jwt}}} ->
        {:ok, signed_jwt}

      {:ok, %Req.Response{} = response} ->
        {:error, {:service_account_sign_jwt, response}}

      {:error, reason} ->
        {:error, {:service_account_sign_jwt, reason}}
    end
  end

  defp claim_set(impersonation_email, service_account_email, scope, token_endpoint) do
    unix_timestamp = :os.system_time(:seconds)

    %{
      "iss" => service_account_email,
      "scope" => scope,
      "aud" => token_endpoint,
      "sub" => impersonation_email,
      "exp" => unix_timestamp + 3600,
      "iat" => unix_timestamp
    }
  end

  defp exchange_signed_jwt(jwt, config) do
    payload =
      URI.encode_query(%{
        "grant_type" => @jwt_bearer_grant_type,
        "assertion" => jwt
      })

    Req.post(
      config[:token_endpoint],
      [
        headers: [{"Content-Type", "application/x-www-form-urlencoded"}],
        body: payload
      ] ++ request_opts(config)
    )
  end

  defp access_token_response(
         {:ok,
          %Req.Response{
            status: 200,
            body: %{"access_token" => access_token, "expires_in" => expires_in}
          }}
       ) do
    {:ok, %{token: access_token, expires_in: expires_in}}
  end

  # Keep final OAuth errors untagged because both credential paths share this
  # exchange; treating them as federation failures would trigger a key fallback.
  defp access_token_response({:ok, %Req.Response{} = response}), do: {:error, response}
  defp access_token_response({:error, _reason} = error), do: error

  defp workspace_cache_key(impersonation_email, scope, {:federated, config}) do
    {
      :workspace_access_token,
      :federated,
      config.provider,
      config.audience,
      config.service_account_email,
      impersonation_email,
      scope
    }
  end

  defp workspace_cache_key(impersonation_email, scope, {:service_account_key, key}) do
    key_id =
      key["private_key_id"] ||
        (:sha256
         |> :crypto.hash(key["private_key"] || inspect(key))
         |> Base.encode16(case: :lower))

    {:workspace_access_token, :service_account_key, key["client_email"], key_id,
     impersonation_email, scope}
  end

  def get_customer(access_token) do
    "/admin/directory/v1/customers/my_customer"
    |> get(access_token)
  end

  @doc """
  Fetches one user by Google user id or primary email.
  """
  def get_user(access_token, user_key) do
    get("/admin/directory/v1/users/#{URI.encode(user_key)}", access_token)
  end

  @doc """
  Opens a push notification channel for every user event in the customer account.
  """
  def watch_users(access_token, channel) when is_map(channel) do
    query = URI.encode_query(%{"customer" => "my_customer"})
    post("/admin/directory/v1/users/watch?#{query}", access_token, channel)
  end

  @doc """
  Closes a push notification channel.
  """
  def stop_channel(access_token, channel_id, resource_id) do
    post("/admin/directory_v1/channels/stop", access_token, %{
      "id" => channel_id,
      "resourceId" => resource_id
    })
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
    query = URI.encode_query(params)
    url = "#{config[:endpoint]}#{path}?#{query}"

    case Req.get(url, [headers: [Authorization: "Bearer #{access_token}"]] ++ request_opts(config)) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> other
    end
  end

  @active_user_query "isSuspended=false isArchived=false"

  @doc """
  Streams active users across every domain in the customer account.
  Returns a stream that yields pages of users.
  """
  def stream_users(access_token) do
    query =
      URI.encode_query(%{
        "customer" => "my_customer",
        "maxResults" => "500",
        "projection" => "full",
        "query" => @active_user_query
      })

    stream_pages("/admin/directory/v1/users", query, access_token, "users")
    |> Stream.map(&filter_active_google_users_result/1)
  end

  @doc """
  Streams groups from the Google Workspace directory.
  Returns a stream that yields pages of groups.

  ## Options

    * `:query` - optional query string passed directly to the API `query` parameter
      (e.g. `"email:firezone-sync*"` to filter by email prefix server-side)
    * `:domain` - restrict to a single domain; omit to cover every domain in the
      customer account
  """
  def stream_groups(access_token, opts \\ []) do
    params = %{
      "customer" => "my_customer",
      "maxResults" => "200"
    }

    params =
      case Keyword.get(opts, :query) do
        nil -> params
        q -> Map.put(params, "query", q)
      end

    params =
      case Keyword.get(opts, :domain) do
        nil -> params
        domain -> Map.put(params, "domain", domain)
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
        case get_users_chunk(access_token, chunk) do
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

  # The batch endpoint answers 200 even when parts are throttled, so Req's retry
  # never sees those. Re-sending the whole chunk is cheaper than tracking parts.
  defp get_users_chunk(access_token, chunk, retry_count \\ 0) do
    case do_batch_get_users(access_token, chunk) do
      {:throttled, _response} when retry_count < @max_retries ->
        Process.sleep(batch_retry_delay(retry_count))
        get_users_chunk(access_token, chunk, retry_count + 1)

      {:throttled, response} ->
        {:error, response}

      result ->
        result
    end
  end

  # Req schedules its own retries; per-part ones are ours, same setting.
  defp batch_retry_delay(retry_count) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    case Keyword.get(config[:req_opts] || [], :retry_delay) do
      nil -> retry_delay(retry_count)
      milliseconds when is_integer(milliseconds) -> milliseconds
      fun when is_function(fun, 1) -> fun.(retry_count)
    end
  end

  defp do_batch_get_users(access_token, user_ids) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)
    req_opts = request_opts(config)
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

        {:throttled, _} = throttled ->
          {:halt, throttled}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, users} -> {:ok, Enum.reverse(users)}
      other -> other
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
         status when status in [200, 403, 404] <- extract_http_status(status_and_headers) do
      case status do
        404 ->
          {:ok, []}

        403 ->
          parse_forbidden_batch_part(json_body)

        200 ->
          decode_json_user(json_body)
      end
    else
      status when is_integer(status) and status not in [200, 403, 404] ->
        log_batch_parse_issue("Failing batch users response part with unexpected status",
          status: status
        )

        normalized_status = normalize_status(status)

        {:error,
         %Req.Response{status: normalized_status, body: %{"error" => "Batch users part failed"}}}

      malformed ->
        log_batch_parse_issue("Failing malformed batch users response part",
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

  defp parse_forbidden_batch_part(json_body) do
    if usage_limits_error?(String.trim(json_body)) do
      {:throttled,
       %Req.Response{status: 403, body: %{"error" => "Batch users part throttled"}}}
    else
      log_batch_parse_issue("Failing batch users response part with unexpected status",
        status: 403
      )

      {:error, %Req.Response{status: 403, body: %{"error" => "Batch users part failed"}}}
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

    (config[:endpoint] <> path)
    |> Req.get([headers: [Authorization: "Bearer #{access_token}"]] ++ request_opts(config))
  end

  defp post(path, access_token, json) do
    config = Portal.Config.fetch_env!(:portal, __MODULE__)

    (config[:endpoint] <> path)
    |> Req.post(
      [headers: [Authorization: "Bearer #{access_token}"], json: json] ++ request_opts(config)
    )
  end

  # Throttling is a 403 with domain "usageLimits", not a 429, so Req's built-in
  # strategies miss it. A custom predicate replaces them, hence the repetition.
  # https://developers.google.com/workspace/admin/directory/v1/limits
  @usage_limits_domain "usageLimits"
  @transient_statuses [408, 429, 500, 502, 503, 504]
  @transient_transport_reasons [:timeout, :econnrefused, :closed]
  @transient_http_reasons [:unprocessed, :pool_not_available]

  # Config may switch retrying off, but must not swap in another strategy.
  defp request_opts(config) do
    req_opts = config[:req_opts] || []

    retry =
      case Keyword.fetch(req_opts, :retry) do
        {:ok, false} -> false
        _otherwise -> &retry_google_error/2
      end

    req_opts
    |> Keyword.put(:retry, retry)
    |> Keyword.put_new(:retry_delay, &retry_delay/1)
    |> Keyword.put_new(:max_retries, @max_retries)
  end

  defp retry_google_error(_request, %Req.Response{status: 403, body: body}) do
    usage_limits_error?(body)
  end

  defp retry_google_error(_request, %Req.Response{status: status}) do
    status in @transient_statuses
  end

  defp retry_google_error(_request, %Req.TransportError{reason: reason}) do
    reason in @transient_transport_reasons
  end

  # Cold Finch pools reject this way right after a deploy, POSTs included.
  defp retry_google_error(_request, %Req.HTTPError{reason: reason}) do
    reason in @transient_http_reasons
  end

  defp retry_google_error(_request, _response_or_exception), do: false

  # The retry step runs before the body is decoded, so this sees raw JSON.
  defp usage_limits_error?(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> usage_limits_error?(decoded)
      {:error, _reason} -> false
    end
  end

  defp usage_limits_error?(%{"error" => %{"errors" => errors}}) when is_list(errors) do
    Enum.any?(errors, &(Map.get(&1, "domain") == @usage_limits_domain))
  end

  defp usage_limits_error?(_body), do: false

  # Truncated exponential backoff, as Google documents it.
  defp retry_delay(retry_count) do
    Integer.pow(2, retry_count) * 1000 + :rand.uniform(1000)
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
    url = "#{config[:endpoint]}#{current_path}?#{current_query}"

    case Req.get(url, [headers: [Authorization: "Bearer #{access_token}"]] ++ request_opts(config)) do
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
