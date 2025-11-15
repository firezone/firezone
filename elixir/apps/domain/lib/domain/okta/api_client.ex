defmodule Domain.Okta.APIClient do
  @moduledoc """
  Client for authenticating with Okta using OAuth 2.0 client assertions.

  Supports DPoP (Demonstration of Proof-of-Possession) authentication method.
  """

  alias Domain.Okta.Directory
  alias Domain.Okta.APIClient
  alias Domain.Okta.ReqDPoP
  alias Domain.Crypto.JWK
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

  @spec new(%Directory{}) :: t()
  def new(%Directory{} = directory) do
    %APIClient{
      base_url: "https://#{directory.okta_domain}",
      client_id: directory.client_id,
      private_key: directory.private_key_jwk,
      kid: directory.kid
    }
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
      |> JOSE.JWS.sign(Jason.encode!(claims), header)
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
  @spec test_connection(t(), String.t()) :: :ok | {:error, Req.Response.t()}
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

    Req.new(base_url: client.base_url)
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
  Fetches groups from the Okta API using the provided access token.
  """
  @spec list_groups(t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_groups(client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: @groups_path)
    |> list_all()
  end

  @doc """
  Fetches users from the Okta API using the provided access token.
  """
  @spec list_users(t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_users(client, access_token) do
    new_request(client, access_token)
    |> Req.merge(
      url: @users_path,
      headers: [
        {"Content-Type", "application/json; okta-response=omitCredentials,omitCredentialsLinks"}
      ],
      params: [fields: "id,status,profile:(firstName,lastName)"]
    )
    |> list_all()
  end

  @spec list_group_members(String.t(), t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_group_members(group_id, client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "#{@groups_path}/#{group_id}/users", params: [limit: 1])
    |> list_all()
  end

  @spec list_apps(t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_apps(client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "api/v1/apps")
    |> list_all()
  end

  @spec list_app_groups(String.t(), t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_app_groups(app_id, client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "/api/v1/apps/#{app_id}/groups", params: [expand: "group", limit: 1])
    |> list_all()
  end

  @spec list_app_users(String.t(), t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_app_users(app_id, client, access_token) do
    new_request(client, access_token)
    |> Req.merge(url: "/api/v1/apps/#{app_id}/users", params: [expand: "user", limit: 1])
    |> list_all()
  end

  defp new_request(%APIClient{} = client, access_token, nonce \\ nil) do
    Req.new(base_url: client.base_url)
    |> ReqDPoP.attach(
      sign_fun: &dpop_sign(&1, client.private_key, client.kid),
      access_token: access_token,
      nonce: nonce
    )
  end

  @spec list_all(Req.Request.t(), [term()]) :: {:ok, [term()]} | {:error, String.t()}
  defp list_all(req, acc \\ []) do
    case Req.get!(req) do
      %{status: 200, body: items, headers: headers} ->
        case extract_next_cursor(headers) do
          nil ->
            {:ok, acc ++ items}

          next_cursor ->
            Req.merge(req, params: [after: next_cursor])
            |> list_all(acc ++ items)
        end

      other ->
        Logger.warning("Unexpected error while making Okta API request",
          status: other.status,
          headers: inspect(other.headers),
          response: inspect(other.body)
        )

        {:error, "Unexpected Error"}
    end
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
      |> JOSE.JWS.sign(Jason.encode!(claims), header)
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

  defp test_endpoint(client, token, endpoint, opts) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, [])

    new_request(client, token)
    |> Req.merge(url: endpoint, headers: headers, params: params)
    |> Req.get!()
    |> case do
      %{status: 200, body: [_result]} ->
        :ok

      resp ->
        Logger.warning(
          "Error during Okta endpoint test",
          endpoint: endpoint,
          status: resp.status,
          headers: inspect(resp.headers),
          response: inspect(resp.body)
        )

        {:error, resp}
    end
  end

  defp test_apps(client, token) do
    test_endpoint(client, token, @apps_path, params: [limit: 1])
  end

  defp test_users(client, token) do
    test_endpoint(client, token, @users_path,
      headers: [
        {"Content-Type", "application/json; okta-response=omitCredentials,omitCredentialsLinks"}
      ],
      params: [limit: 1]
    )
  end

  defp test_groups(client, token) do
    test_endpoint(client, token, @groups_path, params: [limit: 1])
  end
end

defmodule Domain.Okta.ReqDPoP do
  @moduledoc """
  Req plugin that (re)generates a DPoP proof per attempt by wrapping the adapter.
  """

  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts) do
    req
    |> Req.Request.register_options([:sign_fun, :nonce, :access_token])
    |> Req.Request.merge_options(opts)
    |> wrap_adapter()
    |> Req.Request.merge_options(retry: &retry/2)
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

  # Prefer Okta's x-rate-limit-reset (unix seconds). If missing, fall back to Retry-After.
  defp delay_from_rate_limit_headers(headers) do
    now_s = System.system_time(:second)

    with reset when is_binary(reset) <- get_header(headers, "x-rate-limit-reset"),
         {reset_s, ""} <- Integer.parse(reset) do
      max(reset_s - now_s, 0) * 1000
    else
      _ ->
        case get_header(headers, "retry-after") do
          nil ->
            default_backoff_ms()

          val ->
            case Integer.parse(val) do
              {sec, ""} -> max(sec, 1) * 1000
              # TODO: Handle HTTP-date value
              :error -> default_backoff_ms()
            end
        end
    end
  end

  defp get_header(headers, name) when is_map(headers) do
    case Map.get(headers, String.downcase(name)) do
      [v | _] -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp default_backoff_ms(), do: 1000

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
