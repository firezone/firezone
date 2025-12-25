defmodule Portal.MembershipFixtures do
  @moduledoc """
  Test helpers for creating memberships (actor-group relationships).
  """

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.GroupFixtures

  @doc """
  Generate valid membership attributes with sensible defaults.
  """
  def valid_membership_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{})
  end

  @doc """
  Generate a membership with valid default attributes.

  The membership will be created with an associated account, actor, and group
  unless they are provided.

  ## Examples

      membership = membership_fixture()
      membership = membership_fixture(actor: actor, group: group)
      membership = membership_fixture(account: account)

  """
  def membership_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    # Determine the account to use:
    # 1. If actor is provided, use its account
    # 2. Else if group is provided, use its account
    # 3. Else if account is provided, use it
    # 4. Else create a new account
    account =
      cond do
        actor = Map.get(attrs, :actor) ->
          actor.account || Portal.Repo.preload(actor, :account).account

        group = Map.get(attrs, :group) ->
          group.account || Portal.Repo.preload(group, :account).account

        true ->
          Map.get(attrs, :account) || account_fixture()
      end

    # Get or create actor
    actor = Map.get(attrs, :actor) || actor_fixture(account: account)

    # Get or create group
    group = Map.get(attrs, :group) || group_fixture(account: account)

    # Build membership attrs - use IDs directly to avoid association issues
    membership_attrs =
      attrs
      |> Map.delete(:account)
      |> Map.delete(:actor)
      |> Map.delete(:group)
      |> Map.put(:account_id, account.id)
      |> Map.put(:actor_id, actor.id)
      |> Map.put(:group_id, group.id)
      |> valid_membership_attrs()

    {:ok, membership} =
      %Portal.Membership{}
      |> Ecto.Changeset.cast(membership_attrs, [
        :last_synced_at,
        :account_id,
        :actor_id,
        :group_id
      ])
      |> Portal.Membership.changeset()
      |> Portal.Repo.insert()

    membership
  end

  @doc """
  Generate a synced membership (from identity provider).
  """
  def synced_membership_fixture(attrs \\ %{}) do
    membership_fixture(Map.put(attrs, :last_synced_at, DateTime.utc_now()))
  end

  @doc """
  Create multiple memberships for the same actor.
  """
  def actor_memberships_fixture(actor, group_count \\ 3, attrs \\ %{}) do
    account = actor.account || Portal.Repo.preload(actor, :account).account

    for _ <- 1..group_count do
      group = group_fixture(account: account)
      membership_fixture(Map.merge(attrs, %{actor: actor, group: group, account: account}))
    end
  end

  @doc """
  Create multiple memberships for the same group.
  """
  def group_memberships_fixture(group, actor_count \\ 3, attrs \\ %{}) do
    account = group.account || Portal.Repo.preload(group, :account).account

    for _ <- 1..actor_count do
      actor = actor_fixture(account: account)
      membership_fixture(Map.merge(attrs, %{actor: actor, group: group, account: account}))
    end
  end
end
