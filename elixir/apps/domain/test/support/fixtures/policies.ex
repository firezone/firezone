defmodule Domain.Fixtures.Policies do
  use Domain.Fixture
  alias Domain.Policies

  def policy_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      description: "because of #{unique_integer()}"
    })
  end

  def create_policy(attrs \\ %{}) do
    attrs = policy_attrs(attrs)

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

    {actor_group_id, attrs} =
      pop_assoc_fixture_id(attrs, :actor_group, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, subject: subject})
        |> Fixtures.Actors.create_group()
      end)

    {resource_id, attrs} =
      pop_assoc_fixture_id(attrs, :resource, fn ->
        Fixtures.Resources.create_resource(account: account, subject: subject)
      end)

    {:ok, policy} =
      attrs
      |> Map.put(:actor_group_id, actor_group_id)
      |> Map.put(:resource_id, resource_id)
      |> Domain.Policies.create_policy(subject)

    policy
  end

  def disable_policy(policy) do
    policy = Repo.preload(policy, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: policy.account,
        actor: [type: :account_admin_user]
      )

    {:ok, policy} = Policies.disable_policy(policy, subject)
    policy
  end

  def delete_policy(policy) do
    policy = Repo.preload(policy, :account)

    subject =
      Fixtures.Auth.create_subject(
        account: policy.account,
        actor: [type: :account_admin_user]
      )

    {:ok, policy} = Policies.delete_policy(policy, subject)
    policy
  end
end
