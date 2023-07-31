defmodule Domain.GatewaysFixtures do
  alias Domain.AccountsFixtures
  alias Domain.Repo
  alias Domain.Gateways
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures}

  def group_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name_prefix: "group-#{counter()}",
      tags: ["aws", "aws-us-east-#{counter()}"],
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

    {:ok, group} = Gateways.create_group(attrs, subject)
    group
  end

  def delete_group(group) do
    group = Repo.preload(group, :account)
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: group.account)
    identity = AuthFixtures.create_identity(account: group.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
    {:ok, group} = Gateways.delete_group(group, subject)
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
        {%Gateways.Group{} = group, _attrs} ->
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

    Gateways.Token.Changeset.create_changeset(account, subject)
    |> Ecto.Changeset.put_change(:group_id, group.id)
    |> Repo.insert!()
  end

  def gateway_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      name_suffix: "gw-#{Domain.Crypto.rand_string(5)}",
      public_key: public_key(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}}
    })
  end

  def create_gateway(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {group, attrs} =
      case Map.pop(attrs, :group, %{}) do
        {%Gateways.Group{} = group, attrs} ->
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

    attrs = gateway_attrs(attrs)

    {:ok, gateway} = Gateways.upsert_gateway(token, attrs)
    gateway
  end

  def delete_gateway(gateway) do
    gateway = Repo.preload(gateway, :account)
    actor = ActorsFixtures.create_actor(type: :account_admin_user, account: gateway.account)
    identity = AuthFixtures.create_identity(account: gateway.account, actor: actor)
    subject = AuthFixtures.create_subject(identity)
    {:ok, gateway} = Gateways.delete_gateway(gateway, subject)
    gateway
  end

  def public_key do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
