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

  def create_global_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {group, attrs} =
      pop_assoc_fixture(attrs, :group, fn assoc_attrs ->
        create_global_group(assoc_attrs)
      end)

    {:ok, token, encoded_token} = Relays.create_token(group, attrs)
    context = Fixtures.Auth.build_context(type: :relay_group)
    {:ok, {_account_id, _id, nonce, secret}} = Domain.Tokens.peek_token(encoded_token, context)
    %{token | secret_nonce: nonce, secret_fragment: secret}
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

    {:ok, token, encoded_token} = Relays.create_token(group, attrs, subject)
    context = Fixtures.Auth.build_context(type: :relay_group)
    {:ok, {_account_id, _id, nonce, secret}} = Domain.Tokens.peek_token(encoded_token, context)
    %{token | secret_nonce: nonce, secret_fragment: secret}
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

    {token, attrs} =
      pop_assoc_fixture(attrs, :token, fn assoc_attrs ->
        if group.account_id do
          assoc_attrs
          |> Enum.into(%{account: account, group: group})
          |> create_token()
        else
          assoc_attrs
          |> Enum.into(%{group: group})
          |> create_global_token()
        end
      end)

    {context, attrs} =
      pop_assoc_fixture(attrs, :context, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{type: :relay_group})
        |> Fixtures.Auth.build_context()
      end)

    {:ok, relay} = Relays.upsert_relay(group, token, attrs, context)
    %{relay | online?: false}
  end

  def update_relay(relay, changes) do
    Ecto.Changeset.change(relay, changes)
    |> Repo.update!()
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

  def disconnect_relay(relay) do
    :ok = Domain.Relays.disconnect_relay(relay)

    :ok = Domain.Relays.unsubscribe_from_relay_presence(relay)

    if relay.account_id do
      :ok = Domain.Relays.unsubscribe_from_relays_presence_in_account(relay.account_id)
    end

    :ok = Domain.Relays.unsubscribe_from_relays_presence_in_group(relay.group_id)

    :ok = Domain.PubSub.unsubscribe("relays:#{relay.id}")

    if relay.account_id do
      :ok = Domain.PubSub.unsubscribe("account_relays:#{relay.account_id}")
    end

    :ok = Domain.PubSub.unsubscribe("global_relays")
    :ok = Domain.PubSub.unsubscribe("group_relays:#{relay.group_id}")

    :ok = Domain.Relays.Presence.untrack(self(), "presences:global_relays", relay.id)

    :ok =
      Domain.Relays.Presence.untrack(self(), "presences:group_relays:#{relay.group_id}", relay.id)

    if relay.account_id do
      :ok =
        Domain.Relays.Presence.untrack(
          self(),
          "presences:account_relays:#{relay.account_id}",
          relay.id
        )
    end

    :ok = Domain.Relays.Presence.untrack(self(), "presences:relays:#{relay.id}", relay.id)
  end
end
