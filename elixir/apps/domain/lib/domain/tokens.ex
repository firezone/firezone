defmodule Domain.Tokens do
  alias Domain.Repo
  alias Domain.{Auth, Actors}
  alias Domain.Tokens.{Token, Authorizer, Jobs}
  require Ecto.Query

  alias Domain.{Auth, Accounts}
  alias Domain.Tokens.Token

  def create_token(%Accounts.Account{} = account, attrs) do
    account
    |> Token.Changeset.create(attrs)
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
  def encode_token!(%Token{secret: secret, type: type} = token) when not is_nil(secret) do
    body = {token.account_id, token.id, token.secret}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt <> to_string(type), body)
  end

  def verify_token(account_id, context, encrypted_token, opts \\ []) do
    user_agents_whitelist = Keyword.get(opts, :user_agents_whitelist, [])
    remote_ips_whitelist = Keyword.get(opts, :remote_ips_whitelist, [])

    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)

    with {:ok, {^account_id, id, secret}} <-
           Plug.Crypto.verify(key_base, salt <> to_string(context), encrypted_token,
             max_age: :infinity
           ),
  def use_token(account_id, encrypted_token, %Auth.Context{} = context) do
    with {:ok, {^account_id, id, secret}} <- verify_token(encrypted_token, context),
         queryable =
           Token.Query.by_id(id)
           |> Token.Query.by_account_id(account_id)
           |> Token.Query.by_type(context.type)
           |> Token.Query.not_expired(),
         {:ok, token} <- Repo.fetch(queryable),
         true <- Domain.Crypto.equal?(:sha, secret <> token.secret_salt, token.secret_hash) do
      Token.Changeset.use(token, context)
      |> Repo.update()
    else
      {:error, :invalid} -> {:error, :invalid_or_expired_token}
      {:ok, _token_payload} -> {:error, :invalid_or_expired_token}
      {:error, :not_found} -> {:error, :invalid_or_expired_token}
      false -> {:error, :invalid_or_expired_token}
    end
  end

  defp verify_token(encrypted_token, %Auth.Context{} = context) do
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    shared_salt = Keyword.fetch!(config, :salt)
    salt = shared_salt <> to_string(context.type)

    Plug.Crypto.verify(key_base, salt, encrypted_token, max_age: :infinity)
  end

    end
  end

  def delete_expired_tokens do
    Token.Query.expired()
    |> delete_tokens()
  end

  defp delete_tokens(queryable) do
    {count, _ids} =
      queryable
      |> Ecto.Query.select([tokens: tokens], tokens.id)
      |> Repo.update_all(set: [deleted_at: DateTime.utc_now()])


    {:ok, count}
  end

  def delete_token(%Token{} = token) do
    Token.Query.by_id(token.id)
    |> Repo.fetch_and_update(with: &Token.Changeset.delete/1)
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
