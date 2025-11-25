defmodule Domain.Tokens do
  alias Domain.Repo
  alias Domain.{Auth, Actors, Relays, Gateways, Safe}
  alias Domain.Tokens.Token
  require Ecto.Query
  require Logger

  def fetch_token_by_id(id) do
    Token.Query.all()
    |> Token.Query.not_expired()
    |> Token.Query.by_id(id)
    |> Repo.fetch(Token.Query, [])
  end

  def fetch_token_by_id(id, %Auth.Subject{} = subject) do
    with true <- Repo.valid_uuid?(id) do
      result =
        Token.Query.all()
        |> Token.Query.by_id(id)
        |> scope_tokens_for_subject(subject)
        |> Safe.one()

      case result do
        nil -> {:error, :not_found}
        {:error, :unauthorized} -> {:error, :unauthorized}
        token -> {:ok, token}
      end
    else
      false -> {:error, :not_found}
    end
  end

  def list_subject_tokens(%Auth.Subject{} = subject, opts \\ []) do
    Token.Query.all()
    |> Token.Query.by_actor_id(subject.actor.id)
    |> list_tokens(subject, opts)
  end

  def list_tokens_for(%Actors.Actor{} = actor, %Auth.Subject{} = subject, opts \\ []) do
    case subject.actor.type do
      :account_admin_user ->
        Token.Query.all()
        |> Token.Query.by_actor_id(actor.id)
        |> list_tokens(subject, opts)

      _ ->
        {:error, :unauthorized}
    end
  end

  defp list_tokens(queryable, subject, opts) do
    queryable
    |> Ecto.Query.order_by([tokens: tokens], desc: tokens.inserted_at, desc: tokens.id)
    |> scope_tokens_for_subject(subject)
    |> Safe.list(Token.Query, opts)
  end

  def create_token(attrs) do
    Token.Changeset.create(attrs)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  def create_token(attrs, %Auth.Subject{} = subject) do
    Token.Changeset.create(attrs, subject)
    |> Safe.unscoped()
    |> Safe.insert()
  end

  @doc """
  Update allows to extend the token expiration, which is useful for situations where we can use
  IdP API to refresh the ID token and don't want users to go through redirects every hour
  (hardcoded token duration for Okta and Google Workspace).
  """
  def update_token(%Token{} = token, attrs) do
    Token.Query.all()
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
      |> Safe.unscoped()
      |> Safe.update()
    else
      {:error, :invalid} -> {:error, :invalid_or_expired_token}
      {:ok, _token_payload} -> {:error, :invalid_or_expired_token}
      {:error, :not_found} -> {:error, :invalid_or_expired_token}
      false -> {:error, :invalid_or_expired_token}
      _other -> {:error, :invalid_or_expired_token}
    end
  end

  defp fetch_token_for_use(id, account_id, context_type) do
    Token.Query.all()
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
    |> Safe.unscoped()
    |> Safe.update_all([])
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
    cond do
      # Admin can delete any token in their account
      subject.actor.type == :account_admin_user and subject.account.id == token.account_id ->
        Safe.scoped(token, subject)
        |> Safe.delete()

      # Users can delete their own tokens
      subject.actor.id == token.actor_id and subject.account.id == token.account_id ->
        Safe.scoped(token, subject)
        |> Safe.delete()

      true ->
        {:error, :unauthorized}
    end
  end

  def delete_token_for(%Auth.Subject{} = subject) do
    queryable =
      Token.Query.all()
      |> Token.Query.by_id(subject.token_id)

    case queryable |> Safe.scoped(subject) |> Safe.delete_all() do
      {:error, :unauthorized} -> {:error, :unauthorized}
      {num_deleted, _} -> {:ok, num_deleted}
    end
  end

  def delete_tokens_for(%Relays.Group{} = group, %Auth.Subject{} = subject) do
    case subject.actor.type do
      :account_admin_user ->
        queryable =
          Token.Query.all()
          |> Token.Query.by_relay_group_id(group.id)

        case queryable |> Safe.scoped(subject) |> Safe.delete_all() do
          {:error, :unauthorized} -> {:error, :unauthorized}
          {num_deleted, _} -> {:ok, num_deleted}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def delete_tokens_for(%Gateways.Group{} = group, %Auth.Subject{} = subject) do
    case subject.actor.type do
      :account_admin_user ->
        queryable =
          Token.Query.all()
          |> Token.Query.by_gateway_group_id(group.id)

        case queryable |> Safe.scoped(subject) |> Safe.delete_all() do
          {:error, :unauthorized} -> {:error, :unauthorized}
          {num_deleted, _} -> {:ok, num_deleted}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def delete_expired_tokens do
    {num_deleted, _} =
      Token.Query.all()
      |> Token.Query.expired()
      |> Safe.unscoped()
      |> Safe.delete_all()

    {:ok, num_deleted}
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end

  def socket_id(%Token{} = token), do: socket_id(token.id)
  def socket_id(token_id), do: "sessions:#{token_id}"

  # Helper to scope tokens based on subject permissions
  defp scope_tokens_for_subject(queryable, %Auth.Subject{} = subject) do
    # For tokens, we need to apply additional filters based on actor type
    # Admin users can see all tokens, regular users only see their own
    filtered_query =
      case subject.actor.type do
        :account_admin_user ->
          # Admins can see all tokens in their account
          queryable

        _ ->
          # Regular users can only see their own tokens
          Token.Query.by_actor_id(queryable, subject.actor.id)
      end

    Safe.scoped(filtered_query, subject)
  end
end
