defmodule Domain.Fixtures.Tokens do
  use Domain.Fixture

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
      expires_at: expires_at
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

    {:ok, token} = Domain.Auth.create_token(attrs)
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

    {:ok, token} = Domain.Auth.create_token(attrs, subject)
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
          Repo.get!(Domain.Actor, relation.actor_id)
        else
          assoc_attrs
          |> Enum.into(%{account: account})
          |> Fixtures.Actors.create_actor()
        end
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        case actor.type do
          :service_account ->
            %{id: nil}

          :api_client ->
            %{id: nil}

          _ ->
            assoc_attrs
            |> Enum.into(%{account: account, actor: actor})
            |> Fixtures.Auth.create_identity()
        end
      end)

    attrs = Map.put(attrs, :account_id, account.id)
    attrs = Map.put(attrs, :actor_id, actor.id)
    attrs = Map.put(attrs, :identity_id, identity.id)

    {:ok, token} = Domain.Auth.create_token(attrs)
    token
  end

  def create_client_token(attrs \\ %{}) do
    attrs = attrs |> Enum.into(%{type: :client}) |> token_attrs()

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> Fixtures.Actors.create_actor()
      end)

    {identity, attrs} =
      pop_assoc_fixture(attrs, :identity, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: actor})
        |> Fixtures.Auth.create_identity()
      end)

    attrs = Map.put(attrs, :account_id, account.id)
    attrs = Map.put(attrs, :actor_id, actor.id)
    attrs = Map.put(attrs, :identity_id, identity.id)

    {:ok, token} = Domain.Auth.create_token(attrs)
    token
  end

  def create_api_client_token(attrs \\ %{}) do
    attrs = token_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {actor, attrs} =
      pop_assoc_fixture(attrs, :actor, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> Fixtures.Actors.create_actor()
      end)

    {expires_at, attrs} =
      Map.pop_lazy(attrs, :expires_at, fn ->
        DateTime.utc_now() |> DateTime.add(60, :second)
      end)

    {name, attrs} =
      Map.pop_lazy(attrs, :name, fn ->
        "api-token-#{unique_integer()}"
      end)

    {secret_fragment, attrs} =
      Map.pop_lazy(attrs, :secret_fragment, fn ->
        Domain.Crypto.random_token(32, encoder: :hex32)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    attrs =
      Map.merge(attrs, %{
        name: name,
        type: :api_client,
        secret_fragment: secret_fragment,
        account_id: actor.account_id,
        actor_id: actor.id,
        expires_at: expires_at
      })

    {:ok, token} = Domain.Auth.create_token(attrs, subject)
    token
  end

  def delete_token(token) do
    Domain.Repo.delete(token)
  end

  def expire_token(token) do
    one_minute_ago = DateTime.utc_now() |> DateTime.add(-1, :minute)

    token
    |> Ecto.Changeset.change(expires_at: one_minute_ago)
    |> Domain.Repo.update!()
  end
end
