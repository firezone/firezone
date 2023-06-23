# TODO: Domain.Fixtures.Resources
defmodule Domain.ResourcesFixtures do
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, GatewaysFixtures}

  def resource_attrs(attrs \\ %{}) do
    address = "admin-#{counter()}.mycorp.com"

    Enum.into(attrs, %{
      address: address,
      name: address,
      type: :dns,
      filters: [
        %{protocol: :tcp, ports: [80, 433]},
        %{protocol: :udp, ports: [100..200]}
      ]
    })
  end

  def create_resource(attrs \\ %{}) do
    attrs = resource_attrs(attrs)

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    {connections, attrs} =
      Map.pop_lazy(attrs, :gateway_groups, fn ->
        Enum.map(1..2, fn _ ->
          gateway = GatewaysFixtures.create_gateway(account: account)
          %{gateway_group_id: gateway.group_id}
        end)
      end)

    {subject, attrs} =
      Map.pop_lazy(attrs, :subject, fn ->
        actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
        identity = AuthFixtures.create_identity(account: account, actor: actor)
        AuthFixtures.create_subject(identity)
      end)

    {:ok, resource} =
      attrs
      |> Map.put(:connections, connections)
      |> Domain.Resources.create_resource(subject)

    resource
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
