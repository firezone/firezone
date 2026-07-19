# Vendored from https://github.com/firezone/openid_connect, a fork of
# https://github.com/DockYard/openid_connect by DockYard, Inc.
# MIT licensed; see lib/openid_connect/LICENSE.md.
defmodule OpenIDConnect do
  @moduledoc """
  Handles a majority of the life-cycle concerns with [OpenID Connect](http://openid.net/connect/)
  """
  alias OpenIDConnect.Document
  alias OpenIDConnect.Document.Cache

  @typedoc """
  URL to a [OpenID Discovery Document](https://openid.net/specs/openid-connect-discovery-1_0.html) endpoint.
  """
  @type discovery_document_uri :: String.t()

  @typedoc """
  OAuth 2.0 Client Identifier valid at the Authorization Server.
  """
  @type client_id :: String.t()

  @typedoc """
  OAuth 2.0 Client Secret valid at the Authorization Server.
  """
  @type client_secret :: String.t()

  @typedoc """
  Redirection URI to which the response will be sent.

  This URI MUST exactly match one of the Redirection URI values for the Client pre-registered at the OpenID Provider,
  with the matching performed as described in Section 6.2.1 of [RFC3986] (Simple String Comparison).

  When using this flow, the Redirection URI SHOULD use the https scheme; however, it MAY use the http scheme,
  provided that the Client Type is confidential, as defined in Section 2.1 of OAuth 2.0,
  and provided the OP allows the use of http Redirection URIs in this case. The Redirection URI MAY use an alternate scheme,
  such as one that is intended to identify a callback into a native application.
  """
  @type redirect_uri :: String.t()

  @typedoc """
  OAuth 2.0 Response Type value that determines the authorization processing flow to be used,
  including what parameters are returned from the endpoints used.
  """
  @type response_type :: [String.t()] | String.t()

  @typedoc """
  OAuth 2.0 Scope Values that the Client is declaring that it will restrict itself to using.
  """
  @type scope :: [String.t()] | String.t()

  @typedoc """
  The configuration of a OpenID provider.
  """
  @type config :: %{
          required(:discovery_document_uri) => discovery_document_uri(),
          required(:client_id) => client_id(),
          required(:client_secret) => client_secret(),
          required(:response_type) => response_type(),
          required(:scope) => scope(),
          optional(:leeway) => non_neg_integer(),
          optional(:req_opts) => keyword()
        }

  @typedoc """
  JSON Web Token

  See: https://jwt.io/introduction/
  """
  @type jwt :: String.t()

  @doc """
  Builds the authorization URI according to the spec in the providers discovery document

  The `params` option can be used to add additional query params to the URI

  Example:
      OpenIDConnect.authorization_uri(:google, %{"hd" => "dockyard.com"})

  > It is *highly suggested* that you add the `state` param for security reasons. Your
  > OpenID Connect provider should have more information on this topic.
  """
  @spec authorization_uri(
          config(),
          redirect_uri :: redirect_uri(),
          params :: %{optional(atom) => term()}
        ) :: {:ok, uri :: String.t()} | {:error, term()}
  def authorization_uri(config, redirect_uri, params \\ %{}) do
    discovery_document_uri = config.discovery_document_uri
    req_opts = Map.get(config, :req_opts, [])

    with {:ok, document} <- Document.fetch_document(discovery_document_uri, req_opts),
         {:ok, response_type} <- fetch_response_type(config, document),
         {:ok, scope} <- fetch_scope(config) do
      params =
        Map.merge(
          %{
            client_id: config.client_id,
            redirect_uri: redirect_uri,
            response_type: response_type,
            scope: scope
          },
          params
        )

      {:ok, build_uri(document.authorization_endpoint, params)}
    end
  end

  defp fetch_scope(%{scope: scope}) when is_nil(scope) or scope == [] or scope == "",
    do: {:error, :invalid_scope}

  defp fetch_scope(%{scope: scope}) when is_binary(scope),
    do: {:ok, scope}

  defp fetch_scope(%{scope: scopes}) when is_list(scopes),
    do: {:ok, Enum.join(scopes, " ")}

  # Providers advertise supported response type *combinations* (normalized to
  # sorted token order by `Document.build_document/1`), so compare the whole
  # combination rather than its individual tokens.
  defp fetch_response_type(
         %{response_type: response_type},
         %Document{response_types_supported: response_types_supported}
       ) do
    with {:ok, response_type} <- parse_response_type(response_type) do
      response_type = response_type |> Enum.sort() |> Enum.join(" ")

      if response_type in response_types_supported do
        {:ok, response_type}
      else
        {:error,
         {:response_type_not_supported, response_types_supported: response_types_supported}}
      end
    end
  end

  defp parse_response_type(nil), do: {:error, :invalid_response_type}
  defp parse_response_type([]), do: {:error, :invalid_response_type}
  defp parse_response_type(""), do: {:error, :invalid_response_type}

  defp parse_response_type(response_type) when is_binary(response_type),
    do: {:ok, String.split(response_type)}

  defp parse_response_type(response_type) when is_list(response_type),
    do: {:ok, response_type}

  @doc """
  Builds the end session URI according to the spec in the providers discovery document

  The `params` option can be used to add additional query params to the URI

  Example:
    OpenIDConnect.end_session_uri(:azure, %{"client_id" => "5d4c39b4-660f-41c9-9a99-2a6a9c263f07"})

  See more about this feature of the OpenID Connect spec:
    https://openid.net/specs/openid-connect-rpinitiated-1_0.html

  Each provider will typically require one or more of the supported query params, e.g. `id_token_hint` or
  `client_id`. Read your provider's OIDC documentation to determine which one(s) you should add.

  Some providers don't specify `end_session_endpoint` in their discovery documents,
  in such cases `{:error, :endpoint_not_set}` is returned.
  """
  @spec end_session_uri(config(), params :: %{optional(atom) => term()}) ::
          {:ok, uri :: String.t()} | {:error, term()}
  def end_session_uri(config, params \\ %{}) do
    discovery_document_uri = config.discovery_document_uri
    req_opts = Map.get(config, :req_opts, [])

    with {:ok, document} <- Document.fetch_document(discovery_document_uri, req_opts) do
      if end_session_endpoint = document.end_session_endpoint do
        params = Map.merge(%{client_id: config.client_id}, params)
        {:ok, build_uri(end_session_endpoint, params)}
      else
        {:error, :endpoint_not_set}
      end
    end
  end

  @doc """
  Fetches the authentication tokens from the provider using the token endpoint retrieved from a discovery document.

  The `params` option depends on the `grant_type`:

    * for "authorization_code" grant type, `params` should at least include the `redirect_uri` and `code` params;
    * for "refresh_token" grant type, `params` should at least include the `refresh_token` param;
    * for other grant types and more details see the
    [OpenID Connect spec](https://openid.net/specs/openid-connect-core-1_0.html#TokenEndpoint).

  `params` may also include any one-off overrides for token fetching.
  """
  @spec fetch_tokens(config(), params :: %{optional(atom) => term()}) ::
          {:ok, response :: map()} | {:error, term()}
  def fetch_tokens(config, params) do
    discovery_document_uri = config.discovery_document_uri
    req_opts = Map.get(config, :req_opts, [])

    form_params =
      %{client_id: config.client_id, client_secret: config.client_secret}
      |> Map.merge(params)

    request =
      req_opts
      |> Keyword.merge(form: form_params, retry: retry_option())
      |> Req.new()

    with {:ok, document} <- Document.fetch_document(discovery_document_uri, req_opts),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           Req.post(request, url: document.token_endpoint) do
      {:ok, decode_body(body)}
    else
      {:ok, %{status: status, body: body}} -> {:error, {status, decode_body(body)}}
      other -> other
    end
  end

  @doc """
  Verifies the validity of the JSON Web Token (JWT)

  This verification will assert the token's encryption against the provider's
  JSON Web Key (JWK)
  """
  @spec verify(config(), jwt :: String.t()) ::
          {:ok, claims :: map()} | {:error, term()}
  def verify(config, jwt) do
    discovery_document_uri = config.discovery_document_uri
    req_opts = Map.get(config, :req_opts, [])

    with {:ok, token_alg, token_kid} <- peek_token_header(jwt) do
      verify_with_retry(config, jwt, token_alg, token_kid, discovery_document_uri, req_opts)
    end
  end

  defp verify_with_retry(config, jwt, token_alg, token_kid, uri, req_opts) do
    # Snapshot pre-call so we only retry when JWKS was cached (cold cache = already fresh).
    pre_cached = Cache.peek(uri)

    case do_verify(config, jwt, token_alg, uri, req_opts) do
      {:error, {:invalid_jwt, "verification failed"}} = error ->
        retry_verify(config, jwt, token_alg, token_kid, uri, req_opts, pre_cached, error)

      result ->
        result
    end
  end

  # Refresh out-of-band so a failed refetch (provider unreachable) leaves the old
  # cached JWKS intact for legitimate cached-key-signed tokens. `allow_refresh?`
  # enforces a per-URI cooldown to throttle DoS via unknown-kid spam.
  defp retry_verify(config, jwt, token_alg, token_kid, uri, req_opts, pre_cached, error) do
    with true <- should_refresh_jwks?(token_kid, pre_cached),
         true <- Cache.allow_refresh?(uri),
         {:ok, _fresh} <- Document.refresh_document(uri, req_opts) do
      do_verify(config, jwt, token_alg, uri, req_opts)
    else
      _ -> error
    end
  end

  # Only refresh on an unexpired cached doc whose JWKS lacks the token's kid —
  # otherwise it's either a cold cache, a tampered token, or already refetched.
  defp should_refresh_jwks?(kid, {:ok, %Document{jwks: jwks, expires_at: expires_at}})
       when is_binary(kid) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :gt and not kid_in_jwks?(kid, jwks)
  end

  defp should_refresh_jwks?(_kid, _pre_cached), do: false

  defp kid_in_jwks?(kid, %JOSE.JWK{keys: {:jose_jwk_set, jwks}}) do
    Enum.any?(jwks, fn raw_jwk ->
      raw_jwk |> JOSE.JWK.from() |> jwk_kid() == kid
    end)
  end

  defp kid_in_jwks?(kid, %JOSE.JWK{} = jwk), do: jwk_kid(jwk) == kid
  defp kid_in_jwks?(_kid, _jwks), do: false

  defp jwk_kid(%JOSE.JWK{fields: fields}), do: Map.get(fields, "kid")
  defp jwk_kid(_), do: nil

  defp peek_token_header(jwt) do
    with {:ok, protected} <- peek_protected(jwt),
         {:ok, decoded_protected} <- JSON.decode(protected),
         {:ok, token_alg} <- Map.fetch(decoded_protected, "alg") do
      {:ok, token_alg, Map.get(decoded_protected, "kid")}
    else
      {:error, {:unexpected_end, _position}} ->
        {:error, {:invalid_jwt, "token header JSON is incomplete"}}

      {:error, {:invalid_byte, _position, _byte}} ->
        {:error, {:invalid_jwt, "token header contains invalid JSON"}}

      {:error, {:unexpected_sequence, _position, _bytes}} ->
        {:error, {:invalid_jwt, "token header contains invalid UTF-8 escape sequence"}}

      {:error, :peek_protected} ->
        {:error, {:invalid_jwt, "invalid token format"}}

      :error ->
        {:error, {:invalid_jwt, "no `alg` found in token"}}
    end
  end

  defp do_verify(config, jwt, token_alg, discovery_document_uri, req_opts) do
    with {:ok, document} <- Document.fetch_document(discovery_document_uri, req_opts),
         {true, claims, _jwk} <- verify_signature(document.jwks, token_alg, jwt),
         {:ok, unverified_claims} <- JSON.decode(claims),
         {:ok, verified_claims} <- verify_claims(unverified_claims, config) do
      {:ok, verified_claims}
    else
      {:error, {:unexpected_end, _position}} ->
        {:error, {:invalid_jwt, "token claims JSON is incomplete"}}

      {:error, {:invalid_byte, _position, _byte}} ->
        {:error, {:invalid_jwt, "token claims contain invalid JSON"}}

      {:error, {:unexpected_sequence, _position, _bytes}} ->
        {:error, {:invalid_jwt, "token claims contain invalid UTF-8 escape sequence"}}

      {:error, invalid_claim, message} ->
        {:error, {:invalid_jwt, "invalid #{invalid_claim} claim: #{message}"}}

      {false, _claims, _jwk} ->
        {:error, {:invalid_jwt, "verification failed"}}

      {:error, {:case_clause, _}} ->
        {:error, {:invalid_jwt, "verification failed"}}

      other ->
        other
    end
  end

  defp peek_protected(jwt) do
    {:ok, JOSE.JWS.peek_protected(jwt)}
  rescue
    _ -> {:error, :peek_protected}
  end

  defp verify_signature(%JOSE.JWK{keys: {:jose_jwk_set, jwks}}, token_alg, jwt) do
    Enum.find_value(jwks, {false, "{}", jwt}, fn jwk ->
      jwk
      |> JOSE.JWK.from()
      |> verify_signature(token_alg, jwt)
      |> case do
        {false, _claims, _jwt} -> false
        {true, claims, jwt} -> {true, claims, jwt}
        _other -> false
      end
    end)
  end

  defp verify_signature(%JOSE.JWK{} = jwk, token_alg, jwt),
    do: JOSE.JWS.verify_strict(jwk, [token_alg], jwt)

  defp verify_claims(claims, config) do
    leeway = Map.get(config, :leeway, 30)
    client_id = Map.fetch!(config, :client_id)

    with :ok <- verify_exp_claim(claims, leeway),
         :ok <- verify_aud_claim(claims, client_id) do
      {:ok, claims}
    end
  end

  defp verify_exp_claim(claims, leeway) do
    case Map.fetch(claims, "exp") do
      {:ok, exp} when is_integer(exp) ->
        epoch = DateTime.utc_now() |> DateTime.to_unix()

        if epoch < exp + leeway,
          do: :ok,
          else: {:error, "exp", "token has expired"}

      {:ok, _exp} ->
        {:error, "exp", "is invalid"}

      :error ->
        {:error, "exp", "missing"}
    end
  end

  defp verify_aud_claim(claims, expected_aud) do
    case Map.fetch(claims, "aud") do
      {:ok, aud} ->
        if audience_matches?(aud, expected_aud),
          do: :ok,
          else: {:error, "aud", "token is intended for another application"}

      :error ->
        {:error, "aud", "missing"}
    end
  end

  defp audience_matches?(aud, expected_aud) when is_list(aud), do: Enum.member?(aud, expected_aud)
  defp audience_matches?(aud, expected_aud), do: aud === expected_aud

  @doc "Fetches the userinfo claims for `access_token` from the provider's userinfo endpoint."
  def fetch_userinfo(config, access_token) do
    discovery_document_uri = config.discovery_document_uri
    req_opts = Map.get(config, :req_opts, [])

    headers = [{"Authorization", "Bearer #{access_token}"}]

    request =
      req_opts
      |> Keyword.merge(headers: headers, retry: retry_option())
      |> Req.new()

    with {:ok, document} <- Document.fetch_document(discovery_document_uri, req_opts),
         true <- not is_nil(document.userinfo_endpoint),
         {:ok, %{status: status, body: body}} when status in 200..299 <-
           Req.get(request, url: document.userinfo_endpoint) do
      {:ok, decode_body(body)}
    else
      {:ok, %{status: status, body: body}} -> {:error, {status, decode_body(body)}}
      false -> {:error, :userinfo_endpoint_is_not_implemented}
      other -> other
    end
  end

  defp decode_body(nil), do: nil
  defp decode_body(body) when is_map(body), do: body

  defp decode_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, json} -> json
      {:error, _} -> body
    end
  end

  defp build_uri(uri, params) do
    query = URI.encode_query(params)

    uri
    |> URI.merge("?#{query}")
    |> URI.to_string()
  end

  defp retry_option do
    Portal.Config.get_env(:portal, OpenIDConnect, [])
    |> Keyword.get(:retry, :safe_transient)
  end
end
