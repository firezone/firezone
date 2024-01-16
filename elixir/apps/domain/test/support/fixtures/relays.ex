defmodule Domain.Fixtures.Relays do
  use Domain.Fixture
  alias Domain.Relays

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{unique_integer()}"
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

    {:ok, group} = Relays.create_group(attrs, subject)
    group
  end

  def create_global_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)
    {:ok, group} = Relays.create_global_group(attrs)
    group
  end

  def delete_group(group) do
    group = Repo.preload(group, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: group.account,
        actor: [type: :account_admin_user]
      )

    {:ok, group} = Relays.delete_group(group, subject)
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

    {:ok, encoded_token} = Relays.create_token(group, attrs, subject)
    context = Fixtures.Auth.build_context(type: :relay_group)
    {:ok, {_account_id, id, nonce, secret}} = Domain.Tokens.peek_token(encoded_token, context)
    %{Repo.get(Domain.Tokens.Token, id) | secret_nonce: nonce, secret_fragment: secret}
  end

  def relay_attrs(attrs \\ %{}) do
    ipv4 = unique_ipv4()

    Enum.into(attrs, %{
      ipv4: ipv4,
      ipv6: unique_ipv6()
    })
  end

  def create_relay(attrs \\ %{}) do
    attrs = relay_attrs(attrs)

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

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: :relay_group})
        |> Fixtures.Auth.build_context()
      end)

    {:ok, relay} = Relays.upsert_relay(group, attrs, context)
    %{relay | online?: false}
  end

  def delete_relay(relay) do
    relay = Repo.preload(relay, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: relay.account,
        actor: [type: :account_admin_user]
      )

    {:ok, relay} = Relays.delete_relay(relay, subject)
    relay
  end
end
