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

    {actor_group, attrs} =
      Map.pop_lazy(attrs, :actor_group, fn ->
        ActorsFixtures.create_group(account: account, subject: subject)
      end)

    {actor_group_id, attrs} =
      Map.pop_lazy(attrs, :actor_group, fn ->
        actor_group.id
      end)

    {resource, attrs} =
      Map.pop_lazy(attrs, :resource, fn ->
        ResourcesFixtures.create_resource(account: account, subject: subject)
      end)

    {resource_id, attrs} =
      Map.pop_lazy(attrs, :resource, fn ->
        resource.id
      end)

    {:ok, policy} =
      attrs
      |> Map.put(:actor_group_id, actor_group_id)
      |> Map.put(:resource_id, resource_id)
      |> Domain.Policies.create_policy(subject)

    policy
  end

  defp counter do
    System.unique_integer([:positive])
  end
end
