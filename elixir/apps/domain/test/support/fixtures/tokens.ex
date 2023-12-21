defmodule Domain.Fixtures.Tokens do
  use Domain.Fixture
  alias Domain.Tokens

  def remote_ip, do: Enum.random([unique_ipv4(), unique_ipv6()])
  def user_agent, do: "iOS/12.5 (iPhone; #{unique_integer()}) connlib/0.7.412"

  def token_attrs(attrs \\ %{}) do
    type = :browser
    secret = Domain.Crypto.random_token(32)
    expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
    user_agent = Fixtures.Auth.user_agent()
    remote_ip = Fixtures.Auth.remote_ip()

    Enum.into(attrs, %{
      type: type,
      secret: secret,
      expires_at: expires_at,
      created_by_user_agent: user_agent,
      created_by_remote_ip: remote_ip
    })
  end

  def create_email_token(attrs \\ %{}) do
    attrs = attrs |> Enum.into(%{type: :email}) |> token_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    attrs = Map.put(attrs, :account_id, account.id)

    {:ok, token} = Domain.Tokens.create_token(attrs)
    token
  end

  def create_service_account_token(attrs \\ %{}) do
    attrs = token_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, token} = Domain.Tokens.create_token(attrs, subject)
    token
  end

  def create_token(attrs \\ %{}) do
    attrs = token_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    attrs = Map.put(attrs, :account_id, account.id)

    {:ok, token} = Domain.Tokens.create_token(attrs)
    token
  end

  def delete_token(token) do
    token
    |> Tokens.Token.Changeset.delete()
    |> Domain.Repo.update!()
  end

  def expire_token(token) do
    one_minute_ago = DateTime.utc_now() |> DateTime.add(-1, :minute)

    token
    |> Ecto.Changeset.change(expires_at: one_minute_ago)
    |> Domain.Repo.update!()
  end
end
