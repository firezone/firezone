defmodule Domain.Fixtures.Gateways do
  use Domain.Fixture
  alias Domain.Gateways

  def create_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {site, attrs} =
      pop_assoc_fixture(attrs, :site, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> Fixtures.Sites.create_site()
      end)

    {subject, _attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, token, encoded_token} = Sites.create_token(site, attrs, subject)
    context = Fixtures.Auth.build_context(type: :site)
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

    {site, attrs} =
      pop_assoc_fixture(attrs, :site, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account})
        |> Sites.create_site()
      end)

    {_token, attrs} =
      pop_assoc_fixture(attrs, :token, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, site: site})
        |> create_token()
      end)

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: :site})
        |> Fixtures.Auth.build_context()
      end)

    {:ok, gateway} = Gateways.upsert_gateway(site, attrs, context)
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
