defmodule Domain.Tokens do
  use Supervisor
  alias Domain.{Repo, Validator}
  alias Domain.{Auth, Actors}
  alias Domain.Tokens.{Token, Authorizer, Jobs}
  require Ecto.Query

  def start_link(_init_arg) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Domain.Jobs, Jobs}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def fetch_token_by_id(id, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_tokens_permission(),
         Authorizer.manage_own_tokens_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions),
         true <- Validator.valid_uuid?(id) do
      Token.Query.by_id(id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch()
    else
      false -> {:error, :not_found}
      other -> other
    end
  end

  def list_tokens_for(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_tokens_permission()) do
      Token.Query.by_actor_id(subject.actor.id)
      |> list_tokens(subject, [])
    end
  end

  def list_tokens_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts \\ []) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      Token.Query.by_actor_id(actor.id)
      |> list_tokens(subject, opts)
    end
  end

  defp list_tokens(queryable, subject, opts) do
    {preload, _opts} = Keyword.pop(opts, :preload, [])

    {:ok, tokens} =
      queryable
      |> Authorizer.for_subject(subject)
      |> Ecto.Query.order_by([tokens: tokens], desc: tokens.inserted_at, desc: tokens.id)
      |> Repo.list()

    {:ok, Repo.preload(tokens, preload)}
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
    Token.Query.by_id(token.id)
    |> Token.Query.not_expired()
    |> Repo.fetch_and_update(with: &Token.Changeset.update(&1, attrs))
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
         queryable =
           Token.Query.by_id(id)
           |> Token.Query.by_account_id(account_id)
           |> Token.Query.by_type(context.type)
           |> Token.Query.not_expired(),
         {:ok, token} <- Repo.fetch(queryable),
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

  @doc false
  def peek_token(encoded_token, %Auth.Context{} = context) do
    with [nonce, encoded_fragment] <- String.split(encoded_token, ".", parts: 2),
         {:ok, {account_id, id, secret}} <- verify_token(encoded_fragment, context) do
      {:ok, {account_id, id, nonce, secret}}
    end
  end

  defp verify_token(encrypted_token, %Auth.Context{} = context) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    shared_salt = Keyword.fetch!(config, :salt)
    salt = shared_salt <> to_string(context.type)

    Plug.Crypto.verify(key_base, salt, encrypted_token, max_age: :infinity)
  end

  def delete_token(%Token{} = token, %Auth.Subject{} = subject) do
    required_permissions =
      {:one_of,
       [
         Authorizer.manage_tokens_permission(),
         Authorizer.manage_own_tokens_permission()
       ]}

    with :ok <- Auth.ensure_has_permissions(subject, required_permissions) do
      Token.Query.by_id(token.id)
      |> Authorizer.for_subject(subject)
      |> Repo.fetch_and_update(with: &Token.Changeset.delete/1)
      |> case do
        {:ok, token} ->
          Phoenix.PubSub.broadcast(Domain.PubSub, "sessions:#{token.id}", "disconnect")
          {:ok, token}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def delete_tokens_for(%Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_own_tokens_permission()) do
      Token.Query.by_actor_id(subject.actor.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_tokens_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject) do
    with :ok <- Auth.ensure_has_permissions(subject, Authorizer.manage_tokens_permission()) do
      Token.Query.by_actor_id(actor.id)
      |> Authorizer.for_subject(subject)
      |> delete_tokens()
    end
  end

  def delete_expired_tokens do
    Token.Query.expired()
    |> delete_tokens()
  end

  defp delete_tokens(queryable) do
    {count, ids} =
      queryable
      |> Ecto.Query.select([tokens: tokens], tokens.id)
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])

    :ok =
      Enum.each(ids, fn id ->
        # TODO: use Domain.PubSub once it's in the codebase
        Phoenix.PubSub.broadcast(Domain.PubSub, "sessions:#{id}", "disconnect")
      end)

    {:ok, count}
  end

  def delete_token_by_id(token_id) do
    if Validator.valid_uuid?(token_id) do
      Token.Query.by_id(token_id)
      |> delete_tokens()
    else
      {:ok, 0}
    end
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
