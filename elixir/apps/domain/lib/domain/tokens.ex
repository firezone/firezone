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

  def verify_token(%Accounts.Account{} = account, context, secret, opts \\ []) do
    user_agents_whitelist = Keyword.get(opts, :user_agents_whitelist, [])
    remote_ips_whitelist = Keyword.get(opts, :remote_ips_whitelist, [])

    queryable =
      Token.Query.by_account_id(account.id)
      |> Token.Query.by_context(context)
      |> Token.Query.not_expired()

    # TODO: move max use/fail attempts here?
    with {:ok, token} <- Repo.fetch(queryable),
         true <- remote_ips_whitelist == [] or token.remote_ip in remote_ips_whitelist,
         true <- user_agents_whitelist == [] or token.user_agent in user_agents_whitelist,
         true <- Domain.Crypto.equal?(:sha, secret <> token.secret_salt, token.secret_hash) do
      :ok
    else
      _other -> {:error, :invalid_or_expired_token}
    end
  end

  @doc """
  Allows to extend token lifetime by updating token's `expires_at` field.
  """
  def refresh_token(%Token{} = token, attrs) do
    Token.Query.by_id(token.id)
    |> Token.Query.not_expired()
    |> Repo.fetch_and_update(with: &Token.Changeset.refresh(&1, attrs))
  end

  def delete_token(%Token{} = token) do
    Token.Query.by_id(token.id)
    |> Repo.fetch_and_update(with: &Token.Changeset.delete/1)
  end
end
