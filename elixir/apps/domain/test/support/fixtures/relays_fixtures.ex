defmodule Domain.RelaysFixtures do
  alias Domain.Repo
  alias Domain.Relays
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "group-#{counter()}",
      tokens: [%{}]
    })
  end

  def create_group(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
        identity = AuthFixtures.create_identity(account: account, actor: actor)
        AuthFixtures.create_subject(identity)
      end)

    attrs = group_attrs(attrs)

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
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: group.account)
    identity = AuthFixtures.create_identity(account: group.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
    {:ok, group} = Relays.delete_group(group, subject)
    group
  end

  def create_token(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {group, attrs} =
      case Map.pop(attrs, :group, %{}) do
        {%Relays.Group{} = group, attrs} ->
          {group, attrs}

        {group_attrs, attrs} ->
          group_attrs = Enum.into(group_attrs, %{account: account})
          {create_group(group_attrs), attrs}
      end

    {subject, _attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
        identity = AuthFixtures.create_identity(account: account, actor: actor)
        AuthFixtures.create_subject(identity)
      end)

    Relays.Token.Changeset.create_changeset(account, subject)
    |> Ecto.Changeset.put_change(:group_id, group.id)
    |> Repo.insert!()
  end

  def relay_attrs(attrs \\ %{}) do
    ipv4 = random_ipv4()

    Enum.into(attrs, %{
      ipv4: ipv4,
      ipv6: random_ipv6(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: ipv4
    })
  end

  def create_relay(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {group, attrs} =
      case Map.pop(attrs, :group, %{}) do
        {%Relays.Group{} = group, attrs} ->
          {group, attrs}

        {group_attrs, attrs} ->
          group_attrs = Enum.into(group_attrs, %{account: account})
          group = create_group(group_attrs)
          {group, attrs}
      end

    {token, attrs} =
      Map.pop_lazy(attrs, :token, fn ->
        hd(group.tokens)
      end)

    attrs = relay_attrs(attrs)

    {:ok, relay} = Relays.upsert_relay(token, attrs)
    relay
  end

  def delete_relay(relay) do
    relay = Repo.preload(relay, :account)
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: relay.account)
    identity = AuthFixtures.create_identity(account: relay.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
    {:ok, relay} = Relays.delete_relay(relay, subject)
    relay
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end

  defp random_ipv4 do
    number = counter()
    <<a::size(8), b::size(8), c::size(8), d::size(8)>> = <<number::32>>
    {a, b, c, d}
  end

  defp random_ipv6 do
    number = counter()

    <<a::size(16), b::size(16), c::size(16), d::size(16), e::size(16), f::size(16), g::size(16),
      h::size(16)>> = <<number::128>>

    {a, b, c, d, e, f, g, h}
  end
end
