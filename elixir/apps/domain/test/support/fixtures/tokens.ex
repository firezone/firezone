defmodule Domain.Fixtures.Tokens do
  use Domain.Fixture
  alias Domain.Tokens

  def remote_ip, do: Enum.random([unique_ipv4(), unique_ipv6()])
  def user_agent, do: "iOS/12.5 (iPhone; #{unique_integer()}) connlib/0.7.412"

  def token_attrs(attrs \\ %{}) do
    type = :browser
    nonce = Domain.Crypto.random_token(32, encoder: :hex32)
    fragment = Domain.Crypto.random_token(32, encoder: :hex32)
    expires_at = DateTime.utc_now() |> DateTime.add(1, :day)
    user_agent = Fixtures.Auth.user_agent()
    remote_ip = Fixtures.Auth.remote_ip()

    Enum.into(attrs, %{
      type: type,
      secret_nonce: nonce,
      secret_fragment: fragment,
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

    {identity_id, attrs} =
      pop_assoc_fixture_id(attrs, :identity, fn ->
        Fixtures.Auth.create_identity(account: account)
      end)

    attrs = Map.put(attrs, :identity_id, identity_id)
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

    {identity_id, attrs} =
      pop_assoc_fixture_id(attrs, :identity, fn ->
        Fixtures.Auth.create_identity(account: account)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    attrs = Map.put(attrs, :identity_id, identity_id)

    {:ok, token} = Domain.Tokens.create_token(attrs, subject)
    token
  end

  def create_token(attrs \\ %{}) do
    attrs = token_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        relation = attrs[:identity]

        if not is_nil(relation) and is_struct(relation) do
          Repo.get!(Domain.Actors.Actor, relation.actor_id)
        else
          assoc_attrs
          |> Enum.into(%{account: account})
          |> Fixtures.Actors.create_actor()
        end
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        if actor.type == :service_account do
          %{id: nil}
        else
          assoc_attrs
          |> Enum.into(%{account: account, actor: actor})
          |> Fixtures.Auth.create_identity()
        end
      end)

    attrs = Map.put(attrs, :account_id, account.id)
    attrs = Map.put(attrs, :actor_id, actor.id)
    attrs = Map.put(attrs, :identity_id, identity.id)

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
