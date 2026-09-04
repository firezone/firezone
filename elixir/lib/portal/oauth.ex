defmodule Portal.OAuth do
  @moduledoc """
  The OAuth 2.1 authorization server behind the MCP endpoint.

  Only the authorization code grant is supported, only with PKCE, and only for
  public clients: there are no client secrets to leak because clients are
  identified by a metadata document they host themselves. See
  `Portal.OAuth.ClientMetadata`.

  Validation of an authorization request happens in two steps on purpose. Until
  the client and its redirect URI are known good, an error cannot be sent to
  that URI, because doing so would turn this endpoint into an open redirect for
  anyone who can guess a client id. `validate_client/1` covers that first step;
  only after it succeeds may an error be delivered by redirect.
  """

  import Ecto.Changeset

  alias Portal.Authentication
  alias Portal.Authentication.Subject
  alias Portal.OAuth.ClientMetadata
  alias Portal.Scope
  alias Portal.OAuthAuthorizationCode
  alias Portal.OAuthGrant
  alias Portal.OAuthToken
  alias __MODULE__.Database

  @code_ttl_seconds 60
  # RFC 7636 section 4.2: an unpadded base64url SHA-256 is exactly 43 characters.
  @s256_challenge ~r/^[A-Za-z0-9_-]{43}$/
  @access_ttl_seconds 60 * 60
  @refresh_ttl_seconds 30 * 24 * 60 * 60

  defmodule Request do
    @moduledoc """
    A validated authorization request, ready to be shown to the resource owner.
    """

    @enforce_keys [
      :client,
      :redirect_uri,
      :resource,
      :requested_scopes,
      :scopes,
      :code_challenge
    ]
    defstruct [
      :client,
      :redirect_uri,
      :resource,
      :requested_scopes,
      :scopes,
      :code_challenge,
      :state
    ]

    @type t :: %__MODULE__{}
  end

  @doc "Seconds an issued access token remains valid."
  def access_ttl_seconds, do: @access_ttl_seconds

  @doc """
  The single resource this authorization server issues tokens for.

  Tokens are minted for this exact audience and checked against it by the
  resource server on every request, so a token issued for anything else is
  refused even while it is otherwise valid.
  """
  def resource_uri, do: PortalAPI.Endpoint.url() <> "/mcp"

  @doc """
  The cached client for `client_id`, or nil.

  Never fetches the metadata document, so it is safe on a page that renders
  before the request has been validated.
  """
  def cached_client(client_id) when is_binary(client_id),
    do: Database.fetch_cached_client(client_id)

  def cached_client(_client_id), do: nil

  @doc """
  Resolves the client and redirect URI. Errors here **must not** be redirected.
  """
  def validate_client(params) do
    with {:ok, client_id} <- fetch_param(params, "client_id"),
         {:ok, redirect_uri} <- fetch_param(params, "redirect_uri"),
         {:ok, client} <- fetch_client(client_id),
         :ok <- ClientMetadata.validate_redirect_uri(client, redirect_uri) do
      {:ok, client, redirect_uri}
    else
      {:error, :missing_param, param} ->
        {:error, "invalid_request", "#{param} is required."}

      {:error, :invalid_client_id} ->
        {:error, "invalid_client", "client_id must be an https URL with a path."}

      {:error, :invalid_redirect_uri} ->
        {:error, "invalid_request", "redirect_uri is not listed in the client's metadata."}

      {:error, _reason} ->
        {:error, "invalid_client", "The client's metadata document could not be retrieved."}
    end
  end

  @doc """
  Validates the rest of the request. Errors here may be sent to `redirect_uri`.
  """
  def validate_request(params, client, redirect_uri, expected_resource) do
    with :ok <- validate_response_type(params),
         {:ok, challenge} <- validate_pkce(params),
         :ok <- validate_resource(params, expected_resource),
         {:ok, requested_scopes} <- validate_scope(params) do
      {:ok,
       %Request{
         client: client,
         redirect_uri: redirect_uri,
         resource: expected_resource,
         requested_scopes: requested_scopes,
         scopes: default_scopes(requested_scopes),
         code_challenge: challenge,
         state: params["state"]
       }}
    end
  end

  @doc """
  Records consent and mints a single use authorization code.

  The grant is upserted rather than inserted so that re-approving a client with
  different scopes replaces what it had, instead of leaving two rows that
  disagree about what was allowed.
  """
  def consent(%Request{} = request, %Subject{} = subject) do
    with :ok <- validate_granted_scopes(request) do
      Database.transaction(fn -> record_consent(request, subject) end)
    end
  end

  defp record_consent(request, subject) do
    with {:ok, grant} <- upsert_grant(request, subject),
         {:ok, code} <- insert_code(request, grant, subject) do
      {:ok, Authentication.encode_fragment!(code)}
    end
  end

  @doc """
  Exchanges an authorization code for tokens.

  The code row is deleted before anything else is checked, so a code replayed
  in parallel finds nothing even if the first exchange later fails.
  """
  def exchange(params, expected_resource) do
    with {:ok, encoded} <- fetch_param(params, "code"),
         {:ok, verifier} <- fetch_verifier(params),
         {:ok, client_id} <- fetch_param(params, "client_id"),
         {:ok, {nonce, account_id, id, fragment}} <-
           decode(encoded, "mcp_code"),
         {:ok, code} <- Database.take_authorization_code(account_id, id),
         :ok <- Authentication.verify_fragment(code.secret_hash, code.secret_salt, nonce, fragment),
         :ok <- validate_code_freshness(code),
         :ok <- validate_code_binding(code, params, client_id, expected_resource),
         :ok <- validate_verifier(code, verifier) do
      issue(code, expected_resource)
    else
      {:error, :missing_param, param} -> invalid_request("#{param} is required.")
      {:error, reason} -> invalid_grant(reason)
      :error -> invalid_grant(:secret_mismatch)
    end
  end

  @doc """
  Exchanges a refresh token for a new pair, rotating the refresh secret.

  OAuth 2.1 requires rotation for public clients: the old refresh secret stops
  working the moment a new one is handed out, so a stolen copy is good for at
  most one use before the real client's next refresh invalidates it.
  """
  def refresh(params, expected_resource) do
    with {:ok, encoded} <- fetch_param(params, "refresh_token"),
         {:ok, client_id} <- fetch_param(params, "client_id"),
         {:ok, {nonce, account_id, id, fragment}} <- decode(encoded, "mcp_refresh"),
         {:ok, token} <- Database.fetch_refreshable_token(account_id, id),
         :ok <- verify_refresh_secret(token, nonce, fragment),
         :ok <- validate_token_client(token, client_id),
         :ok <- validate_audience(token, expected_resource) do
      rotate(token)
    else
      {:error, :missing_param, param} -> invalid_request("#{param} is required.")
      {:error, reason} -> invalid_grant(reason)
    end
  end

  @doc """
  Revokes a token. Always succeeds, as RFC 7009 requires, so that a caller
  cannot use the endpoint to learn whether a token existed.
  """
  def revoke(encoded) when is_binary(encoded) do
    Enum.each(["mcp", "mcp_refresh"], fn type ->
      with {:ok, {nonce, account_id, id, fragment}} <- decode(encoded, type),
           {:ok, token} <- Database.fetch_token(account_id, id),
           :ok <- verify_revoked_secret(token, type, nonce, fragment) do
        Database.delete_token(account_id, id)
      end
    end)

    :ok
  end

  def revoke(_encoded), do: :ok

  @doc "Every client this actor has connected, newest first."
  def list_grants(%Subject{} = subject), do: Database.list_grants(subject)

  @doc """
  Disconnects a client, deleting the tokens it was issued.

  An id that is not a UUID deletes nothing rather than reaching the query,
  which would raise on the cast.
  """
  def delete_grant(id, %Subject{} = subject) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Database.delete_grant(id, subject)
      :error -> {0, nil}
    end
  end

  defp fetch_client(client_id), do: ClientMetadata.fetch(client_id)

  defp validate_response_type(%{"response_type" => "code"}), do: :ok

  defp validate_response_type(_params),
    do: {:error, "unsupported_response_type", "Only response_type=code is supported."}

  defp validate_pkce(params) do
    case {params["code_challenge"], params["code_challenge_method"]} do
      {nil, _method} ->
        {:error, "invalid_request", "code_challenge is required."}

      {_challenge, method} when method != "S256" ->
        {:error, "invalid_request", "code_challenge_method must be S256."}

      {challenge, "S256"} when is_binary(challenge) ->
        if Regex.match?(@s256_challenge, challenge) do
          {:ok, challenge}
        else
          {:error, "invalid_request", "code_challenge is not a valid S256 challenge."}
        end

      _other ->
        {:error, "invalid_request", "code_challenge is not a valid S256 challenge."}
    end
  end

  # Without a resource parameter a token would have no audience, and a token
  # with no audience is one this server cannot stop being replayed elsewhere.
  defp validate_resource(params, expected_resource) do
    case params["resource"] do
      nil ->
        {:error, "invalid_request", "resource is required."}

      ^expected_resource ->
        :ok

      _other ->
        {:error, "invalid_target", "resource must be #{expected_resource}."}
    end
  end

  # MCP clients need to let the person choose broader access than the initial
  # read-only preset. An omitted scope therefore uses every supported scope as
  # the request ceiling; explicit scopes remain a hard ceiling.
  defp validate_scope(params) do
    case params |> scope_param() |> Scope.parse() do
      {:ok, scopes} ->
        {:ok, scopes}

      {:error, :missing} ->
        {:ok, Scope.all()}

      {:error, {:unknown, unknown}} ->
        {:error, "invalid_scope", "Unknown scopes: #{Enum.join(unknown, ", ")}"}
    end
  end

  defp default_scopes(requested_scopes) do
    Enum.filter(Scope.preset("read"), &(&1 in requested_scopes))
  end

  defp validate_granted_scopes(%Request{} = request) do
    granted = MapSet.new(request.scopes)
    requested = MapSet.new(request.requested_scopes)

    if granted != MapSet.new() and MapSet.subset?(granted, requested) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  # The consent form posts one value per ticked box; a client sends the single
  # space delimited string of RFC 6749.
  defp scope_param(%{"scope" => scopes}) when is_list(scopes), do: Scope.encode(scopes)
  defp scope_param(%{"scope" => scope}), do: scope
  defp scope_param(_params), do: nil

  defp upsert_grant(%Request{} = request, %Subject{} = subject) do
    case Database.fetch_grant(request.client.id, subject) do
      {:ok, grant} ->
        grant
        |> change()
        |> put_change(:scopes, request.scopes)
        |> Database.update_grant(subject)

      :error ->
        %OAuthGrant{}
        |> cast(
          %{
            actor_id: subject.actor.id,
            oauth_client_id: request.client.id,
            scopes: request.scopes
          },
          ~w[actor_id oauth_client_id scopes]a
        )
        |> Database.insert_grant(subject)
    end
  end

  defp insert_code(%Request{} = request, %OAuthGrant{} = grant, %Subject{} = subject) do
    {fragment, salt, hash} = Authentication.generate_token_secrets()

    %OAuthAuthorizationCode{secret_fragment: fragment}
    |> cast(
      %{
        actor_id: grant.actor_id,
        oauth_client_id: request.client.id,
        oauth_grant_id: grant.id,
        secret_salt: salt,
        secret_hash: hash,
        code_challenge: request.code_challenge,
        code_challenge_method: "S256",
        redirect_uri: request.redirect_uri,
        resource: request.resource,
        scopes: request.scopes,
        expires_at: DateTime.add(DateTime.utc_now(), @code_ttl_seconds, :second)
      },
      ~w[actor_id oauth_client_id oauth_grant_id secret_salt secret_hash code_challenge
         code_challenge_method redirect_uri resource scopes expires_at]a
    )
    |> Database.insert_code(subject)
  end

  defp validate_code_freshness(%OAuthAuthorizationCode{} = code) do
    if DateTime.after?(code.expires_at, DateTime.utc_now()) do
      :ok
    else
      {:error, :expired_code}
    end
  end

  defp validate_code_binding(code, params, client_id, expected_resource) do
    cond do
      code.oauth_client.client_id != client_id -> {:error, :client_mismatch}
      code.redirect_uri != params["redirect_uri"] -> {:error, :redirect_uri_mismatch}
      code.resource != expected_resource -> {:error, :resource_mismatch}
      true -> :ok
    end
  end

  defp validate_verifier(%OAuthAuthorizationCode{} = code, verifier) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

    if Plug.Crypto.secure_compare(computed, code.code_challenge) do
      :ok
    else
      {:error, :pkce_mismatch}
    end
  end

  # RFC 7636 fixes the length, so a verifier short enough to guess is refused
  # before it is compared against the challenge.
  defp fetch_verifier(params) do
    case fetch_param(params, "code_verifier") do
      {:ok, verifier} when byte_size(verifier) in 43..128 -> {:ok, verifier}
      {:ok, _verifier} -> {:error, :invalid_verifier}
      error -> error
    end
  end

  # Checked even though revocation always answers 200: without it a refresh
  # secret that has already been rotated out, and so can no longer refresh
  # anything, could still delete the pair that replaced it.
  defp verify_revoked_secret(%OAuthToken{} = token, "mcp", nonce, fragment),
    do: Authentication.verify_fragment(token.secret_hash, token.secret_salt, nonce, fragment)

  defp verify_revoked_secret(
         %OAuthToken{refresh_secret_hash: hash, refresh_secret_salt: salt},
         "mcp_refresh",
         nonce,
         fragment
       )
       when is_binary(hash) and is_binary(salt),
       do: Authentication.verify_fragment(hash, salt, nonce, fragment)

  defp verify_revoked_secret(_token, _type, _nonce, _fragment), do: :error

  # A refresh token is server-signed, so a valid token whose secret no longer
  # matches is a replay of an older rotation rather than attacker-chosen junk.
  # Revoke the family to prevent the party that won the earlier refresh race
  # from retaining control with the replacement token.
  defp verify_refresh_secret(
         %OAuthToken{refresh_secret_hash: hash, refresh_secret_salt: salt} = token,
         nonce,
         fragment
       )
       when is_binary(hash) and is_binary(salt) do
    case Authentication.verify_fragment(
           hash,
           salt,
           nonce,
           fragment
         ) do
      :ok ->
        :ok

      :error ->
        Database.delete_token(token.account_id, token.id)
        {:error, :refresh_token_reuse}
    end
  end

  defp verify_refresh_secret(%OAuthToken{}, _nonce, _fragment),
    do: {:error, :invalid_token}

  # RFC 6749 section 6: a public client names itself on a refresh, and the token
  # it names itself with has to be one that was issued to it.
  defp validate_token_client(%OAuthToken{} = token, client_id) do
    if token.oauth_grant.oauth_client.client_id == client_id do
      :ok
    else
      {:error, :client_mismatch}
    end
  end

  defp validate_audience(%OAuthToken{} = token, expected_resource) do
    if token.resource == expected_resource do
      :ok
    else
      {:error, :resource_mismatch}
    end
  end

  defp issue(%OAuthAuthorizationCode{} = code, resource) do
    {access_fragment, access_salt, access_hash} = Authentication.generate_token_secrets()
    {refresh_fragment, refresh_salt, refresh_hash} = Authentication.generate_token_secrets()
    now = DateTime.utc_now()

    %OAuthToken{
      secret_fragment: access_fragment,
      refresh_secret_fragment: refresh_fragment
    }
    |> cast(
      %{
        account_id: code.account_id,
        actor_id: code.actor_id,
        oauth_grant_id: code.oauth_grant_id,
        secret_salt: access_salt,
        secret_hash: access_hash,
        refresh_secret_salt: refresh_salt,
        refresh_secret_hash: refresh_hash,
        scopes: code.scopes,
        resource: resource,
        expires_at: DateTime.add(now, @access_ttl_seconds, :second),
        refresh_expires_at: DateTime.add(now, @refresh_ttl_seconds, :second)
      },
      ~w[account_id actor_id oauth_grant_id secret_salt secret_hash refresh_secret_salt
         refresh_secret_hash scopes resource expires_at refresh_expires_at]a
    )
    |> Database.insert_token()
    |> case do
      {:ok, token} -> {:ok, token_response(token, access_fragment, refresh_fragment)}
      {:error, _changeset} -> {:error, "server_error", "The token could not be issued."}
    end
  end

  # Compare-and-swap on the verified hash, so two refreshes racing on one secret
  # cannot both succeed.
  defp rotate(%OAuthToken{} = token) do
    {access_fragment, access_salt, access_hash} = Authentication.generate_token_secrets()
    {refresh_fragment, refresh_salt, refresh_hash} = Authentication.generate_token_secrets()
    now = DateTime.utc_now()

    updates = [
      secret_salt: access_salt,
      secret_hash: access_hash,
      refresh_secret_salt: refresh_salt,
      refresh_secret_hash: refresh_hash,
      # Taken from the grant rather than carried over, so approving the same
      # client again with fewer permissions reaches the token it is already
      # holding instead of waiting out its refresh window.
      scopes: token.oauth_grant.scopes,
      expires_at: DateTime.add(now, @access_ttl_seconds, :second),
      refresh_expires_at: DateTime.add(now, @refresh_ttl_seconds, :second),
      updated_at: now
    ]

    case Database.rotate_token(token, updates) do
      {:ok, updated} -> {:ok, token_response(updated, access_fragment, refresh_fragment)}

      :error ->
        # A compare-and-swap failure means another use of this refresh token
        # won the race. Revoke what it rotated to rather than leaving that
        # caller holding the only valid replacement.
        Database.delete_token(token.account_id, token.id)
        invalid_grant(:refresh_token_reuse)
    end
  end

  defp token_response(%OAuthToken{} = token, access_fragment, refresh_fragment) do
    encoded = %{token | secret_fragment: access_fragment, refresh_secret_fragment: refresh_fragment}

    %{
      access_token: Authentication.encode_fragment!(encoded),
      token_type: "Bearer",
      expires_in: @access_ttl_seconds,
      refresh_token: Authentication.encode_refresh_fragment!(encoded),
      scope: Scope.encode(token.scopes)
    }
  end

  defp decode(encoded, type) do
    case Authentication.decode_fragment(encoded, type) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_token}
    end
  end

  defp fetch_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_param, key}
    end
  end

  defp invalid_request(description), do: {:error, "invalid_request", description}

  defp invalid_grant(reason) do
    {:error, "invalid_grant", "The grant is not valid: #{reason}."}
  end

  defmodule Database do
    @moduledoc false
    import Ecto.Query

    alias Portal.OAuthAuthorizationCode
    alias Portal.OAuthGrant
    alias Portal.OAuthToken
    alias Portal.Safe

    def transaction(fun) when is_function(fun, 0) do
      Safe.unscoped()
      |> Safe.transaction(fun)
    end

    def fetch_cached_client(client_id) do
      from(clients in Portal.OAuthClient, where: clients.client_id == ^client_id)
      |> Safe.unscoped()
      |> Safe.one()
    end

    def fetch_grant(oauth_client_id, subject) do
      from(grants in OAuthGrant,
        where: grants.actor_id == ^subject.actor.id,
        where: grants.oauth_client_id == ^oauth_client_id
      )
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> :error
        grant -> {:ok, grant}
      end
    end

    def insert_grant(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def update_grant(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.update()
    end

    def insert_code(changeset, subject) do
      changeset
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    # Deleting and returning in one statement makes the code single use even
    # when two exchanges race: only one delete can match the row.
    def take_authorization_code(account_id, id) do
      from(codes in OAuthAuthorizationCode,
        where: codes.account_id == ^account_id,
        where: codes.id == ^id,
        select: codes
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
      |> case do
        {1, [code]} -> {:ok, %{code | oauth_client: fetch_client(code.oauth_client_id)}}
        _other -> {:error, :unknown_code}
      end
    end

    def insert_token(changeset) do
      changeset
      |> Safe.unscoped()
      |> Safe.insert()
    end

    def rotate_token(%OAuthToken{} = token, updates) do
      from(tokens in OAuthToken,
        where: tokens.account_id == ^token.account_id,
        where: tokens.id == ^token.id,
        where: tokens.refresh_secret_hash == ^token.refresh_secret_hash,
        select: tokens
      )
      |> Safe.unscoped()
      |> Safe.update_all(set: updates)
      |> case do
        {1, [updated]} -> {:ok, updated}
        _other -> :error
      end
    end

    def fetch_refreshable_token(account_id, id) do
      now = DateTime.utc_now()

      from(tokens in OAuthToken,
        where: tokens.account_id == ^account_id,
        where: tokens.id == ^id,
        where: tokens.refresh_expires_at > ^now,
        preload: [oauth_grant: :oauth_client]
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :unknown_token}
        token -> {:ok, token}
      end
    end

    def fetch_token(account_id, id) do
      from(tokens in OAuthToken,
        where: tokens.account_id == ^account_id,
        where: tokens.id == ^id
      )
      |> Safe.unscoped()
      |> Safe.one()
      |> case do
        nil -> {:error, :unknown_token}
        token -> {:ok, token}
      end
    end

    def delete_token(account_id, id) do
      from(tokens in OAuthToken,
        where: tokens.account_id == ^account_id,
        where: tokens.id == ^id
      )
      |> Safe.unscoped()
      |> Safe.delete_all()
    end

    def list_grants(subject) do
      from(grants in OAuthGrant,
        where: grants.actor_id == ^subject.actor.id,
        order_by: [desc: grants.inserted_at],
        preload: [:oauth_client]
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def delete_grant(id, subject) do
      from(grants in OAuthGrant,
        where: grants.id == ^id,
        where: grants.actor_id == ^subject.actor.id
      )
      |> Safe.scoped(subject)
      |> Safe.delete_all()
    end

    defp fetch_client(id) do
      from(clients in Portal.OAuthClient, where: clients.id == ^id)
      |> Safe.unscoped()
      |> Safe.one()
    end
  end
end
