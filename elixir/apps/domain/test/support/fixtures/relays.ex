defmodule Domain.Fixtures.Relays do
  use Domain.Fixture
  alias Domain.Relays

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{unique_integer()}",
      tokens: [%{}]
    })
  end

  def create_group(attrs \\ %{}) do
    attrs = group_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        admin_subject_for_account(account)
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
    subject = admin_subject_for_account(group.account)
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
      Map.pop_lazy(attrs, :subject, fn ->
        admin_subject_for_account(account)
      end)

    Relays.Token.Changeset.create_changeset(account, subject)
    |> Ecto.Changeset.put_change(:group_id, group.id)
    |> Repo.insert!()
  end

  def relay_attrs(attrs \\ %{}) do
    ipv4 = unique_ipv4()

    Enum.into(attrs, %{
      ipv4: ipv4,
      ipv6: unique_ipv6(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: ipv4
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
      Map.pop_lazy(attrs, :token, fn ->
        hd(group.tokens)
      end)

    {:ok, relay} = Relays.upsert_relay(token, attrs)
    %{relay | online?: false}
  end

  def delete_relay(relay) do
    relay = Repo.preload(relay, :account)
    subject = admin_subject_for_account(relay.account)
    {:ok, relay} = Relays.delete_relay(relay, subject)
    relay
  end
end
