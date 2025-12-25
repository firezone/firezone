defmodule Portal.PolicyFixtures do
  @moduledoc """
  Test helpers for creating policies and related data.
  """

  import Portal.AccountFixtures
  import Portal.GroupFixtures
  import Portal.ResourceFixtures

  @doc """
  Generate valid policy attributes with sensible defaults.
  """
  def valid_policy_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      description: "Policy #{unique_num}"
    })
  end

  @doc """
  Generate a policy with valid default attributes.

  The policy will be created with an associated account, group, and resource
  unless they are provided.

  ## Examples

      policy = policy_fixture()
      policy = policy_fixture(description: "Allow access to production")
      policy = policy_fixture(group: group, resource: resource)

  """
  def policy_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Determine the account to use:
    # 1. If group is provided, use its account
    # 2. Else if resource is provided, use its account
    # 3. Else if account is provided, use it
    # 4. Else create a new account
    account =
      cond do
        group = Map.get(attrs, :group) ->
          group.account || Portal.Repo.preload(group, :account).account

        resource = Map.get(attrs, :resource) ->
          resource.account || Portal.Repo.preload(resource, :account).account

        true ->
          Map.get(attrs, :account) || account_fixture()
      end

    # Get or create group
    group = Map.get(attrs, :group) || group_fixture(account: account)

    # Get or create resource
    resource = Map.get(attrs, :resource) || resource_fixture(account: account)

    # Build policy attrs - include the IDs directly
    policy_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:group)
      |> Map.delete(:resource)
      |> Map.put(:account_id, account.id)
      |> Map.put(:group_id, group.id)
      |> Map.put(:resource_id, resource.id)
      |> valid_policy_attrs()

    {:ok, policy} =
      %Portal.Policy{}
      |> Ecto.Changeset.cast(policy_attrs, [
        :description,
        :disabled_at,
        :account_id,
        :group_id,
        :resource_id
      ])
      |> Ecto.Changeset.cast_embed(:conditions,
        with: &Portal.Policies.Condition.changeset(&1, &2, 0)
      )
      |> Portal.Policy.changeset()
      |> Portal.Repo.insert()

    policy
  end

  @doc """
  Generate a disabled policy.
  """
  def disabled_policy_fixture(attrs \\ %{}) do
    policy_fixture(Map.put(attrs, :disabled_at, DateTime.utc_now()))
  end

  @doc """
  Generate a policy with conditions.
  """
  def policy_with_conditions_fixture(attrs \\ %{}) do
    conditions =
      Map.get(attrs, :conditions, [
        %{
          property: :remote_ip,
          operator: :is_in_cidr,
          values: ["10.0.0.0/8"]
        }
      ])

    attrs = Map.put(attrs, :conditions, conditions)
    policy_fixture(attrs)
  end

  @doc """
  Generate a policy with remote IP CIDR condition.
  """
  def policy_with_cidr_condition_fixture(cidrs \\ ["10.0.0.0/8"], attrs \\ %{}) do
    conditions = [
      %{
        property: :remote_ip,
        operator: :is_in_cidr,
        values: cidrs
      }
    ]

    attrs = Map.put(attrs, :conditions, conditions)
    policy_fixture(attrs)
  end

  @doc """
  Generate a policy with provider condition.
  """
  def policy_with_provider_condition_fixture(provider_ids \\ [], attrs \\ %{}) do
    conditions = [
      %{
        property: :provider_id,
        operator: :is_in,
        values: provider_ids
      }
    ]

    attrs = Map.put(attrs, :conditions, conditions)
    policy_fixture(attrs)
  end

  @doc """
  Create multiple policies for the same group.
  """
  def group_policies_fixture(group, resource_count \\ 3, attrs \\ %{}) do
    account = group.account || Portal.Repo.preload(group, :account).account

    for _ <- 1..resource_count do
      resource = resource_fixture(account: account)
      policy_fixture(Map.merge(attrs, %{group: group, resource: resource, account: account}))
    end
  end

  @doc """
  Create multiple policies for the same resource.
  """
  def resource_policies_fixture(resource, group_count \\ 3, attrs \\ %{}) do
    account = resource.account || Portal.Repo.preload(resource, :account).account

    for _ <- 1..group_count do
      group = group_fixture(account: account)
      policy_fixture(Map.merge(attrs, %{group: group, resource: resource, account: account}))
    end
  end

  @doc """
  Update a policy with the given attributes.
  """
  def update_policy(policy, attrs) do
    attrs = Enum.into(attrs, %{})

    policy
    |> Ecto.Changeset.cast(attrs, [:description, :disabled_at])
    |> Ecto.Changeset.cast_embed(:conditions,
      with: &Portal.Policies.Condition.changeset(&1, &2, 0)
    )
    |> Portal.Repo.update!()
  end
end
