defmodule Domain.Tokens do
  alias Domain.Repo
  alias Domain.{Auth, Accounts}
  alias Domain.Tokens.Token

  def create_token(%Accounts.Account{} = account, attrs) do
    account
    |> Token.Changeset.create(attrs)
    |> Repo.insert()
  end

  def create_token(
        %Accounts.Account{id: account_id} = account,
        attrs,
        %Auth.Subject{account: %{id: account_id}} = subject
      ) do
    account
    |> Token.Changeset.create(attrs, subject)
    |> Repo.insert()
  end

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
  def encode_token!(%Token{secret: secret, context: context} = token) when not is_nil(secret) do
    body = {token.account_id, token.id, token.secret}
    config = fetch_config!()
    key_base = Keyword.fetch!(config, :key_base)
    salt = Keyword.fetch!(config, :salt)
    Plug.Crypto.sign(key_base, salt <> to_string(context), body)
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
         queryable =
           Token.Query.by_id(id)
           |> Token.Query.by_account_id(account_id)
           |> Token.Query.by_context(context)
           |> Token.Query.not_expired(),
         {:ok, token} <- Repo.fetch(queryable) do
      ip_valid? =
        remote_ips_whitelist == [] or token.remote_ip in remote_ips_whitelist

      user_agent_valid? =
        user_agents_whitelist == [] or token.user_agent in user_agents_whitelist

      secret_valid? =
        Domain.Crypto.equal?(:sha, secret <> token.secret_salt, token.secret_hash)

      if ip_valid? and user_agent_valid? and secret_valid? do
        :ok
      else
        {:error, :invalid_or_expired_token}
      end
    else
      {:error, :invalid} -> {:error, :invalid_or_expired_token}
      {:ok, _token_payload} -> {:error, :invalid_or_expired_token}
      {:error, :not_found} -> {:error, :invalid_or_expired_token}
    end
  end

  def delete_token(%Token{} = token) do
    Token.Query.by_id(token.id)
    |> Repo.fetch_and_update(with: &Token.Changeset.delete/1)
  end

  defp fetch_config! do
    Domain.Config.fetch_env!(:domain, __MODULE__)
  end
end
