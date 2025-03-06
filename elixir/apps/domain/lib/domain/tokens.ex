defmodule Domain.Tokens do
  use Supervisor
  alias Domain.Repo
  alias Domain.{Auth, Actors, Relays, Gateways}
  alias Domain.Tokens.{Token, Authorizer, Jobs}
  require Ecto.Query

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Jobs.DeleteExpiredTokens,
      Jobs.RefreshBrowserSessionTokens
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def fetch_token_by_id(id, %Auth.Subject{} = subject, opts \\ []) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_tokens_permission(),
         Authorizer.manage_own_tokens_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Repo.valid_uuid?(id) do
      Token.Query.all()
      |> Token.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch(Token.Query, opts)
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def all_active_browser_session_tokens! do
    Token.Query.not_deleted()
    |> Token.Query.expires_in(15, :minute)
    |> Token.Query.by_type(:browser)
    |> Repo.all()
  end

  def list_subject_tokens(%Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_tokens_permission()) do
      Token.Query.not_deleted()
      |> Token.Query.by_actor_id(subject.actor.id)
      |> list_tokens(subject, opts)
    end
  end

  def list_tokens_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      Token.Query.not_deleted()
      |> Token.Query.by_actor_id(actor.id)
      |> list_tokens(subject, opts)
    end
  end

  defp list_tokens(queryable, subject, opts) do
    queryable
    |> Authorizer.for_subject(subject)
    |> Ecto.Query.order_by([tokens: tokens], desc: tokens.inserted_at, desc: tokens.id)
    |> Repo.list(Token.Query, opts)
  end

  def create_token(attrs) do
    Token.Changeset.create(attrs)
    |> Repo.insert()
  end

  def create_token(attrs, %Auth.Subject{} = subject) do
    Token.Changeset.create(attrs, subject)
    |> Repo.insert()
  end

  @doc """
  Update allows to extend the token expiration, which is useful for situations where we can use
  IdP API to refresh the ID token and don't want users to go through redirects every hour
  (hardcoded token duration for Okta and Google Workspace).
  """
  def update_token(%Token{} = token, attrs) do
    Token.Query.not_deleted()
    |> Token.Query.not_expired()
    |> Token.Query.by_id(token.id)
    |> Repo.fetch_and_update(Token.Query, with: &Token.Changeset.update(&1, attrs))
  end

  @doc """
  Token `secret` is used to verify that token can be used only by one source and that it's
  impossible to impersonate a session by knowing what's inside our database.

  It then additionally signed and encoded using `Plug.Crypto.sign/3` to make sure that
  you can't hit our database with requests using a random token id and secret.
  """
  def encode_fragment!(%Token{secret_fragment: fragment, type: type} = token)
      when not is_nil(fragment) do
    body = {token.account_id, token.id, fragment}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    "." <> Plug.Crypto.sign(key_base, salt <> to_string(type), body)
  end

  def use_token(encoded_token, %Auth.Context{} = context) do
    with {:ok, {account_id, id, nonce, secret}} <- peek_token(encoded_token, context),
         {:ok, token} <- fetch_token_for_use(id, account_id, context.type),
         true <-
           Domain.Crypto.equal?(
             :sha3_256,
             nonce <> secret <> token.secret_salt,
             token.secret_hash
           ) do
      Token.Changeset.use(token, context)
      |> Repo.update()
    else
      {:error, :invalid} -> {:error, :invalid_or_expired_token}
      {:ok, _token_payload} -> {:error, :invalid_or_expired_token}
      {:error, :not_found} -> {:error, :invalid_or_expired_token}
      false -> {:error, :invalid_or_expired_token}
      _other -> {:error, :invalid_or_expired_token}
    end
  end

  defp fetch_token_for_use(id, account_id, context_type) do
    Token.Query.not_deleted()
    |> Token.Query.not_expired()
    |> Token.Query.by_id(id)
    |> Token.Query.by_account_id(account_id)
    |> Token.Query.by_type(context_type)
    |> Ecto.Query.update([tokens: tokens],
      set: [
        remaining_attempts:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN ? - 1 ELSE NULL END",
            tokens.remaining_attempts,
            tokens.remaining_attempts
          ),
        expires_at:
          fragment(
            "CASE WHEN ? - 1 = 0 THEN COALESCE(?, timezone('UTC', NOW())) ELSE ? END",
            tokens.remaining_attempts,
            tokens.expires_at,
            tokens.expires_at
          )
      ]
    )
    |> Ecto.Query.select([tokens: tokens], tokens)
    |> Repo.update_all([])
    |> case do
      {1, [token]} -> {:ok, token}
      {0, []} -> {:error, :not_found}
    end
  end

  @doc false
  def peek_token(encoded_token, %Auth.Context{} = context) do
    with [nonce, encoded_fragment] <- String.split(encoded_token, ".", parts: 2),
         {:ok, {account_id, id, secret}} <- verify_token(encoded_fragment, context) do
      {:ok, {account_id, id, nonce, secret}}
    end
  end

  defp verify_token(encoded_fragment, %Auth.Context{} = context) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    shared_salt = Keyword.fetch!(config, :salt)
    salt = shared_salt <> to_string(context.type)
    Plug.Crypto.verify(key_base, salt, encoded_fragment, max_age: :infinity)
  end

  def delete_token(%Token{} = token, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_tokens_permission(),
         Authorizer.manage_own_tokens_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      {:ok, _flows} = Domain.Flows.expire_flows_for(token, subject)

      Token.Query.not_deleted()
      |> Token.Query.by_id(token.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
      |> case do
        {:ok, [token]} -> {:ok, token}
        {:ok, []} -> {:error, :not_found}
      end
    end
  end

  def delete_token_for(%Auth.Subject{} = subject) do
    Token.Query.not_deleted()
    |> Token.Query.by_id(subject.token_id)
    |> Authorizer.for_subject(subject)
    |> delete_tokens()
    |> case do
      {:ok, [token]} ->
        {:ok, _flows} = Domain.Flows.expire_flows_for(token, subject)
        {:ok, token}

      {:ok, []} ->
        {:ok, []}
    end
  end

  def delete_tokens_for(%Auth.Identity{} = identity) do
    {:ok, _flows} = Domain.Flows.expire_flows_for(identity)

    Token.Query.not_deleted()
    |> Token.Query.by_identity_id(identity.id)
    |> delete_tokens()
  end

  def delete_tokens_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      {:ok, _flows} = Domain.Flows.expire_flows_for(actor, subject)

      Token.Query.not_deleted()
      |> Token.Query.by_actor_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_tokens_for(%Auth.Identity{} = identity, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      {:ok, _flows} = Domain.Flows.expire_flows_for(identity, subject)

      Token.Query.not_deleted()
      |> Token.Query.by_identity_id(identity.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_tokens_for(%Auth.Provider{} = provider, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      {:ok, _flows} = Domain.Flows.expire_flows_for(provider, subject)

      Token.Query.not_deleted()
      |> Token.Query.by_provider_id(provider.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_tokens_for(%Relays.Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      Token.Query.not_deleted()
      |> Token.Query.by_relay_group_id(group.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_tokens_for(%Gateways.Group{} = group, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      Token.Query.not_deleted()
      |> Token.Query.by_gateway_group_id(group.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_all_tokens_by_type_and_assoc(:email, %Auth.Identity{} = identity) do
    Token.Query.not_deleted()
    |> Token.Query.by_type(:email)
    |> Token.Query.by_account_id(identity.account_id)
    |> Token.Query.by_identity_id(identity.id)
    |> delete_tokens()
  end

  def delete_expired_tokens do
    Token.Query.not_deleted()
    |> Token.Query.expired()
    |> delete_tokens()
  end

  defp delete_tokens(queryable) do
    {_count, tokens} =
      queryable
      |> Token.Query.delete()
      |> Repo.update_all([])

    :ok = Enum.each(tokens, &broadcast_disconnect_message/1)

    {:ok, tokens}
  end

  defp broadcast_disconnect_message(%{type: :email}) do
    :ok
  end

  defp broadcast_disconnect_message(token) do
    topic = socket_id(token)
    payload = %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
    Phoenix.PubSub.broadcast(Domain.PubSub, topic, payload)
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end

  def socket_id(%Token{} = token), do: socket_id(token.id)
  def socket_id(token_id), do: "sessions:#{token_id}"
end
