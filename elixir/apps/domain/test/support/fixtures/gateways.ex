defmodule Domain.Fixtures.Gateways do
  use Domain.Fixture
  alias Domain.Gateways

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
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, group} = Gateways.create_group(attrs, subject)
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

    Gateways.Token.Changeset.create(account, subject)
    |> Ecto.Changeset.put_change(:group_id, group.id)
    |> Repo.insert!()
  end

  def gateway_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      external_id: Ecto.UUID.generate(),
      hostname: "gw-#{Domain.Crypto.random_token(5, encoder: :user_friendly)}",
      public_key: unique_public_key(),
      last_seen_user_agent: "iOS/12.7 (iPhone) connlib/0.7.412",
      last_seen_remote_ip: %Postgrex.INET{address: {189, 172, 73, 153}},
      last_seen_remote_ip_location_region: "US",
      last_seen_remote_ip_location_city: "San Francisco",
      last_seen_remote_ip_location_lat: 37.7758,
      last_seen_remote_ip_location_lon: -122.4128
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
      Map.pop_lazy(attrs, :token, fn ->
        hd(group.tokens)
      end)

    {:ok, gateway} = Gateways.upsert_gateway(token, attrs)
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
