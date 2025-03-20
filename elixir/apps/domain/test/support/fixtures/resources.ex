defmodule Domain.Fixtures.Resources do
  use Domain.Fixture

  def resource_attrs(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    address = Map.get(attrs, :address, "admin-#{unique_integer()}.mycorp.com")

    Enum.into(attrs, %{
      address: address,
      address_description: "http://#{address}/",
      name: address,
      type: :dns,
      filters: [
        %{protocol: :tcp, ports: [80, 433]},
        %{protocol: :udp, ports: [100..200]},
        %{protocol: :icmp}
      ]
    })
  end

  def create_resource(attrs \\ %{}) do
    attrs = resource_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {connections, attrs} =
      Map.pop_lazy(attrs, :connections, fn ->
        Enum.map(1..2, fn _ ->
          gateway = Fixtures.Gateways.create_gateway(account: account)
          %{gateway_group_id: gateway.group_id}
        end)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    {:ok, resource} =
      attrs
      |> Map.put(:connections, connections)
      |> Domain.Resources.create_resource(subject)

    resource
  end

  def create_internet_resource(attrs \\ %{}) do
    attrs = resource_attrs(attrs)

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

    {:ok, resource} =
      attrs
      |> Map.put(:type, :internet)
      |> Domain.Resources.create_resource(subject)

    resource
  end

  def delete_resource(resource) do
    resource = Repo.preload(resource, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: resource.account,
        actor: [type: :account_admin_user]
      )

    {:ok, resource} = Domain.Resources.delete_resource(resource, subject)
    resource
  end
end
