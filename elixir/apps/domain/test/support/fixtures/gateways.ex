defmodule Domain.Fixtures.Gateways do
  use Domain.Fixture
  alias Domain.Gateways

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{unique_integer()}",
      managed_by: :account
    })
  end

  def create_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)

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

    {:ok, group} = Gateways.create_group(attrs, subject)
    group
  end

  def create_internet_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)

    {account, _attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, group} = Gateways.create_internet_group(account)

    group
  end

  def delete_group(group) do
    group = Repo.preload(group, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: group.account,
        actor: [type: :account_admin_user]
      )

    {:ok, group} = Gateways.delete_group(group, subject)
    group
  end

  def create_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {group, attrs} =
      pop_assoc_fixture(attrs, :group, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> create_group()
      end)

    {subject, _attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, token, encoded_token} = Gateways.create_token(group, attrs, subject)
    context = Fixtures.Auth.build_context(type: :gateway_group)
    {:ok, {_account_id, _id, nonce, secret}} = Domain.Tokens.peek_token(encoded_token, context)
    %{token | secret_nonce: nonce, secret_fragment: secret}
  end

  def gateway_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
      public_key: unique_public_key()
    })
  end

  def create_gateway(attrs \\ %{}) do
    attrs = gateway_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {group, attrs} =
      pop_assoc_fixture(attrs, :group, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> create_group()
      end)

    {token, attrs} =
      pop_assoc_fixture(attrs, :token, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, group: group})
        |> create_token()
      end)

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: :gateway_group})
        |> Fixtures.Auth.build_context()
      end)

    {:ok, gateway} = Gateways.upsert_gateway(group, token, attrs, context)
    %{gateway | online?: false}
  end

  def delete_gateway(gateway) do
    gateway = Repo.preload(gateway, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: gateway.account,
        actor: [type: :account_admin_user]
      )

    {:ok, gateway} = Gateways.delete_gateway(gateway, subject)
    gateway
  end
end
