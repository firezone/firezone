defmodule Portal.Okta.APIClient do
  @moduledoc """
  Client for authenticating with Okta using OAuth 2.0 client assertions.

  Supports DPoP (Demonstration of Proof-of-Possession) authentication method.
  """

  alias Portal.Okta.Directory
  alias Portal.Okta.APIClient
  alias Portal.Okta.ReqDPoP
  alias Portal.Crypto.JWK
  require Logger

  @scopes "okta.users.read okta.groups.read okta.apps.read"

  @token_path "/oauth2/v1/token"
  @groups_path "/api/v1/groups"
  @users_path "/api/v1/users"
  @apps_path "/api/v1/apps"

  @type t :: %__MODULE__{
          base_url: String.t() | nil,
          client_id: String.t() | nil,
          private_key: map() | nil,
          kid: String.t() | nil
        }

  defstruct base_url: nil,
            client_id: nil,
            private_key: nil,
            kid: nil

  @spec new(Directory.t()) :: t()
  def new(%Directory{} = directory) do
    new(directory.okta_domain, directory.client_id, directory.private_key_jwk, directory.kid)
  end

  @spec new(String.t(), String.t(), map(), String.t()) :: t()
  def new(okta_domain, client_id, private_key_jwk, kid) do
    %APIClient{
      base_url: "https://#{okta_domain}",
      client_id: client_id,
      private_key: private_key_jwk,
      kid: kid
    }
  end

  @spec dpop_sign(map(), map(), String.t()) :: String.t()
  def dpop_sign(claims, key, kid) do
    header = %{
      "alg" => "RS256",
      "typ" => "dpop+jwt",
      "kid" => kid,
      "jwk" => JWK.extract_public_key_components(key)
    }

    {_type, dpop_jwt} =
      key
      |> JOSE.JWK.from_map()
      |> JOSE.JWS.sign(JSON.encode!(claims), header)
      |> JOSE.JWS.compact()

    dpop_jwt
  end

  @doc """
  Fetches an access token for the given directory using OAuth 2.0 client assertions.

  Attempts DPoP authentication first with automatic nonce handling, falls back to
  standard client assertion if DPoP is not supported.
  """
  @spec fetch_access_token(t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, Req.Response.t()}
  def fetch_access_token(%APIClient{} = client, nonce \\ nil) do
    # Create client assertion JWT for authentication
    token_url = client.base_url <> @token_path
    client_assertion = create_client_assertion(client, token_url)

    # Form data for token request
    form_data = %{
      "grant_type" => "client_credentials",
      "scope" => @scopes,
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => client_assertion
    }

    # Create request with DPoP support (no access token for token endpoint)
    req =
      new_request(client, nil, nonce)
      |> Req.Request.put_header("content-type", "application/x-www-form-urlencoded")

    case Req.post(req, url: @token_path, form: form_data) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body["access_token"]}

      {:ok,
       %{status: 400, headers: %{"dpop-nonce" => [nonce]}, body: %{"error" => "use_dpop_nonce"}}} ->
        fetch_access_token(client, nonce)

      {:ok, response} ->
        # Unexpected 2xx or 3xx response
        {:error, response}

      {:error, reason} ->
        # Unexpected 4xx or 5xx error response
        {:error, reason}
    end
  end

  @doc """
  Makes test API calls to verify the access token works.
  """
  @spec test_connection(t(), String.t()) ::
          :ok
          | {:error, Req.Response.t()}
          | {:error, :empty, :apps | :users | :groups}
          | {:error, Exception.t()}
  def test_connection(client, access_token) do
    with :ok <- test_apps(client, access_token),
         :ok <- test_users(client, access_token),
         :ok <- test_groups(client, access_token) do
      :ok
    end
  end

  @doc """
  Introspects Okta API access token.

  Used for debugging.
  """
  @spec introspect_token(t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def introspect_token(client, access_token) do
    client_assertion = create_client_assertion(client, client.base_url <> "/oauth2/v1/introspect")

    form_data = %{
      "token" => access_token,
      "token_type_hint" => "access_token",
      "grant_type" => "client_credentials",
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => client_assertion
    }

    req_opts =
      [base_url: client.base_url]
      |> Keyword.merge(req_opts())

    Req.new(req_opts)
    |> Req.merge(url: "/oauth2/v1/introspect")
    |> Req.Request.put_header("content-type", "application/x-www-form-urlencoded")
    |> Req.post(form: form_data)
    |> case do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      _ ->
        {:error, "unable to introspect"}
    end
  end

  @doc """
  Fetches all apps from the Okta API (legacy - prefer stream_apps/2).

  Returns all apps in a list. For large result sets, consider using stream_apps/2 instead.
  """
  @spec list_apps(t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_apps(client, access_token) do
    stream_apps(client, access_token) |> collect_stream_results()
  end

  @doc """
  Streams groups from the Okta PortalAPI.

  Returns a Stream that emits `{:ok, group}` or `{:error, reason}` tuples.
  Lazily fetches pages as needed, keeping only one page in memory at a time.

  ## Examples

      APIClient.stream_groups(client, token)
      |> Stream.filter(fn
        {:ok, _group} -> true
        {:error, _reason} -> false
      end)
      |> Enum.take(10)
  """
  @spec stream_groups(t(), String.t()) :: Enumerable.t()
  def stream_groups(client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: @groups_path, params: [limit: 200])
    |> stream_all()
  end

  @doc """
  Streams users from the Okta PortalAPI.

  Returns a Stream that emits `{:ok, user}` or `{:error, reason}` tuples.
  Lazily fetches pages as needed, keeping only one page in memory at a time.

  ## Examples

      APIClient.stream_users(client, token)
      |> Stream.map(fn
        {:ok, user} -> {:ok, parse_user(user)}
        error -> error
      end)
      |> Enum.to_list()
  """
  @spec stream_users(t(), String.t()) :: Enumerable.t()
  def stream_users(client, access_token) do
    new_request(client, access_token)
    |> Req.merge(
      url: @users_path,
      headers: [
        {"Content-Type", "application/json; okta-response=omitCredentials,omitCredentialsLinks"}
      ],
      params: [fields: "id,status,profile:(firstName,lastName)", limit: 200]
    )
    |> stream_all()
  end

  @doc """
  Streams members of a specific group from the Okta PortalAPI.

  Returns a Stream that emits `{:ok, member}` or `{:error, reason}` tuples.
  Lazily fetches pages as needed, keeping only one page in memory at a time.
  """
  @spec stream_group_members(String.t(), t(), String.t()) :: Enumerable.t()
  def stream_group_members(group_id, client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "#{@groups_path}/#{group_id}/users", params: [limit: 200])
    |> stream_all()
  end

  @doc """
  Streams apps from the Okta PortalAPI.

  Returns a Stream that emits `{:ok, app}` or `{:error, reason}` tuples.
  Lazily fetches pages as needed, keeping only one page in memory at a time.
  """
  @spec stream_apps(t(), String.t()) :: Enumerable.t()
  def stream_apps(client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "api/v1/apps", params: [limit: 200])
    |> stream_all()
  end

  @doc """
  Streams groups assigned to a specific app from the Okta PortalAPI.

  Returns a Stream that emits `{:ok, app_group}` or `{:error, reason}` tuples.
  Lazily fetches pages as needed, keeping only one page in memory at a time.
  """
  @spec stream_app_groups(String.t(), t(), String.t()) :: Enumerable.t()
  def stream_app_groups(app_id, client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "/api/v1/apps/#{app_id}/groups", params: [expand: "group", limit: 200])
    |> stream_all()
  end

  @doc """
  Streams users assigned to a specific app from the Okta PortalAPI.

  Returns a Stream that emits `{:ok, app_user}` or `{:error, reason}` tuples.
  Lazily fetches pages as needed, keeping only one page in memory at a time.
  """
  @spec stream_app_users(String.t(), t(), String.t()) :: Enumerable.t()
  def stream_app_users(app_id, client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "/api/v1/apps/#{app_id}/users", params: [expand: "user", limit: 500])
    |> stream_all()
  end

  defp new_request(%APIClient{} = client, access_token, nonce \\ nil) do
    req_opts =
      [base_url: client.base_url]
      |> Keyword.merge(req_opts())

    Req.new(req_opts)
    |> ReqDPoP.attach(
      sign_fun: &dpop_sign(&1, client.private_key, client.kid),
      access_token: access_token,
      nonce: nonce
    )
  end

  # Collects a stream of {:ok, item} or {:error, reason} tuples into a result.
  # Returns {:ok, [items]} if all successful, or {:error, reason} on first error.
  @spec collect_stream_results(Enumerable.t()) :: {:ok, [term()]} | {:error, String.t()}
  defp collect_stream_results(stream) do
    stream
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, item}, {:ok, acc} ->
        {:cont, {:ok, [item | acc]}}

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  # Creates a stream that lazily fetches paginated results from Okta PortalAPI.
  #
  # Returns a Stream that emits {:ok, item} or {:error, reason} tuples.
  # Keeps only one page in memory at a time.
  @spec stream_all(Req.Request.t()) :: Enumerable.t()
  defp stream_all(req) do
    Stream.resource(
      # Start function - returns initial state
      fn -> {req, nil} end,
      # Next function - fetches next page and returns {items, new_state} or {:halt, state}
      fn
        :halt ->
          {:halt, :halt}

        {request, cursor} ->
          # Merge cursor param if we have one
          request =
            if cursor do
              Req.merge(request, params: [after: cursor])
            else
              request
            end

          case Req.get!(request) do
            %{status: 200, body: items, headers: headers} ->
              next_cursor = extract_next_cursor(headers)
              # Wrap each item in {:ok, item}
              ok_items = Enum.map(items, &{:ok, &1})

              if next_cursor do
                {ok_items, {request, next_cursor}}
              else
                {ok_items, :halt}
              end

            %{status: 401} ->
              {[{:error, "Authentication Error"}], :halt}

            %{status: 403} ->
              {[{:error, "Authorization Error"}], :halt}

            %{status: status, headers: headers, body: body} ->
              Logger.warning("Unexpected response while making Okta API request",
                status: status,
                headers: inspect(headers),
                response: inspect(body)
              )

              {[{:error, "Unexpected response with status #{status}"}], :halt}
          end
      end,
      # After function - (nothing needed here)
      fn _state -> :ok end
    )
  end

  defp create_client_assertion(%APIClient{} = client, token_endpoint) do
    now = System.system_time(:second)
    expiration = now + 60 * 5
    jti_suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    jti = "#{now}_#{jti_suffix}"

    claims = %{
      "iss" => client.client_id,
      "sub" => client.client_id,
      "aud" => token_endpoint,
      "exp" => expiration,
      "iat" => now,
      "jti" => jti
    }

    header = %{"alg" => "RS256", "kid" => client.kid}

    {_type, jwt} =
      client.private_key
      |> JOSE.JWK.from_map()
      |> JOSE.JWS.sign(JSON.encode!(claims), header)
      |> JOSE.JWS.compact()

    jwt
  end

  defp extract_next_cursor(%{"link" => links} = _headers) do
    Enum.find(links, &String.contains?(&1, "rel=\"next\""))
    |> case do
      nil -> nil
      link -> extract_cursor_from_link(link)
    end
  end

  defp extract_next_cursor(_headers), do: nil

  defp extract_cursor_from_link(link) do
    with [_, url] <- Regex.run(~r/<([^>]+)>/, link),
         %URI{query: q} when is_binary(q) <- URI.parse(url),
         %{"after" => cursor} <- URI.decode_query(q) do
      cursor
    else
      _ -> nil
    end
  end

  defp test_endpoint(client, token, endpoint, resource, opts) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, [])

    new_request(client, token)
    |> Req.merge(url: endpoint, headers: headers, params: params)
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: [_result]}} ->
        :ok

      {:ok, %{status: 200, body: []}} ->
        {:error, :empty, resource}

      {:ok, resp} ->
        Logger.warning(
          "Error during Okta endpoint test",
          endpoint: endpoint,
          status: resp.status,
          headers: inspect(resp.headers),
          response: inspect(resp.body)
        )

        {:error, resp}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp test_apps(client, token) do
    test_endpoint(client, token, @apps_path, :apps, params: [limit: 1])
  end

  defp test_users(client, token) do
    test_endpoint(client, token, @users_path, :users,
      headers: [
        {"Content-Type", "application/json; okta-response=omitCredentials,omitCredentialsLinks"}
      ],
      params: [limit: 1]
    )
  end

  defp test_groups(client, token) do
    test_endpoint(client, token, @groups_path, :groups, params: [limit: 1])
  end

  defp req_opts do
    Portal.Config.fetch_env!(:portal, __MODULE__)
    |> Keyword.fetch!(:req_opts)
  end
end

defmodule Portal.Okta.ReqDPoP do
  @moduledoc """
  Req plugin that (re)generates a DPoP proof per attempt by wrapping the adapter.
  """

  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts) do
    req =
      req
      |> Req.Request.register_options([:sign_fun, :nonce, :access_token])
      |> Req.Request.merge_options(opts)
      |> wrap_adapter()

    # Only set custom retry if not already explicitly set (allows tests to disable retries)
    if is_nil(req.options[:retry]) do
      Req.Request.merge_options(req, retry: &retry/2)
    else
      req
    end
  end

  defp retry(%Req.Request{} = req, %Req.Response{} = resp) do
    method_safe? = req.method in [:get, :head]

    case resp.status do
      429 ->
        {:delay, delay_from_rate_limit_headers(resp.headers)}

      408 when method_safe? ->
        true

      status when status in [500, 502, 503, 504] and method_safe? ->
        # For 503, if Retry-After is set, Req would use it by default.
        # Returning `true` keeps default delay behavior (Retry-After or backoff).
        true

      _ ->
        false
    end
  end

  # Handle all other response errors as non-retry-able
  # Example: %Req.TransportError{}, %Req.HTTPError{}, etc...
  defp retry(_req, _), do: false

  # Prefer Okta's x-rate-limit-reset (unix seconds). If missing, fall back to Retry-After, then default backoff.
  defp delay_from_rate_limit_headers(headers) do
    delay_from_x_rate_limit_reset(headers) ||
      delay_from_retry_after(headers) ||
      default_backoff_ms()
  end

  defp delay_from_x_rate_limit_reset(headers) do
    now_s = System.system_time(:second)

    with reset when is_binary(reset) <- get_header(headers, "x-rate-limit-reset"),
         {reset_s, ""} <- Integer.parse(reset) do
      max(reset_s - now_s, 0) * 1000
    else
      _ -> nil
    end
  end

  defp delay_from_retry_after(headers) do
    case get_header(headers, "retry-after") do
      nil -> nil
      val -> parse_retry_after_seconds(val)
    end
  end

  defp parse_retry_after_seconds(val) do
    case Integer.parse(val) do
      {sec, ""} -> max(sec, 1) * 1000
      :error -> nil
    end
  end

  defp get_header(headers, name) when is_map(headers) do
    case Map.get(headers, String.downcase(name)) do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp default_backoff_ms, do: 1000

  defp wrap_adapter(%Req.Request{adapter: orig} = req) do
    Req.Request.put_private(req, :dpop_orig_adapter, orig)
    |> Map.put(:adapter, &adapter_with_dpop/1)
  end

  defp adapter_with_dpop(%Req.Request{} = req) do
    now = System.system_time(:second)
    exp = now + 300
    jti = "#{now}_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

    claims =
      %{
        "htm" => req.method |> to_string() |> String.upcase(),
        "htu" => htu_string(req.url),
        "iat" => now,
        "exp" => exp,
        "jti" => jti
      }
      |> maybe_put_ath(req.options[:access_token])
      |> maybe_put_nonce(req.options[:nonce])

    dpop = req.options[:sign_fun].(claims)

    req =
      req
      |> Req.Request.put_header("dpop", dpop)
      |> maybe_put_auth(req.options[:access_token])

    orig = Req.Request.get_private(req, :dpop_orig_adapter, &Req.Steps.run_finch/1)
    orig.(req)
  end

  defp maybe_put_auth(req, nil), do: req

  defp maybe_put_auth(req, token),
    do: Req.Request.put_header(req, "authorization", "DPoP " <> token)

  defp maybe_put_nonce(map, nil), do: map
  defp maybe_put_nonce(map, nonce), do: Map.put(map, "nonce", nonce)

  defp maybe_put_ath(map, nil), do: map

  defp maybe_put_ath(map, access_token) do
    ath = :crypto.hash(:sha256, access_token) |> Base.url_encode64(padding: false)
    Map.put(map, "ath", ath)
  end

  defp htu_string(%URI{scheme: s, host: h, path: p}), do: s <> "://" <> h <> (p || "/")
end
