defmodule Domain.PoliciesFixtures do
  alias Domain.{AccountsFixtures, ActorsFixtures, AuthFixtures, ResourcesFixtures}

  def policy_attrs(attrs \\ %{}) do
    name = "policy-#{counter()}"

    Enum.into(attrs, %{
      name: name,
      actor_group_id: nil,
      resource_id: nil
    })
  end

  def create_policy(attrs \\ %{}) do
    attrs = policy_attrs(attrs)

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

    {actor_group_id, attrs} =
      Map.pop_lazy(attrs, :actor_group, fn ->
        actor = ActorsFixtures.create_group(account: account, subject: subject)
        actor.id
      end)

    {resource_id, attrs} =
      Map.pop_lazy(attrs, :resource, fn ->
        resource = ResourcesFixtures.create_resource(account: account, subject: subject)
        resource.id
      end)

    {:ok, policy} =
      attrs
      |> Map.put(:actor_group_id, actor_group_id)
      |> Map.put(:resource_id, resource_id)
      |> Domain.Policies.create_policy(subject)

    policy
  end

  # def create_resource(attrs \\ %{}) do
  #  attrs = resource_attrs(attrs)

  #  {account, attrs} =
  #    Map.pop_lazy(attrs, :account, fn ->
  #      AccountsFixtures.create_account()
  #    end)

  #  {connections, attrs} =
  #    Map.pop_lazy(attrs, :gateway_groups, fn ->
  #      Enum.map(1..2, fn _ ->
  #        gateway = GatewaysFixtures.create_gateway(account: account)
  #        %{gateway_group_id: gateway.group_id}
  #      end)
  #    end)

  #  {subject, attrs} =
  #    Map.pop_lazy(attrs, :subject, fn ->
  #      actor = ActorsFixtures.create_actor(type: :account_admin_user, account: account)
  #      identity = AuthFixtures.create_identity(account: account, actor: actor)
  #      AuthFixtures.create_subject(identity)
  #    end)

  #  {:ok, resource} =
  #    attrs
  #    |> Map.put(:connections, connections)
  #    |> Domain.Resources.create_resource(subject)

  #  resource
  # end

  defp counter do
    System.unique_integer([:positive])
  end
end
