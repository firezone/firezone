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
        :account_id,
        :actor_id,
        :group_id
      ])
      |> Portal.Membership.changeset()
      |> Portal.Repo.insert()

    # If synced_at was provided, create a sync state record
    if synced_at = Map.get(membership_attrs, :synced_at) do
      %Portal.MembershipSyncState{
        membership_id: membership.id,
        account_id: account.id,
        synced_at: synced_at
      }
      |> Portal.Repo.insert!(
        on_conflict: {:replace, [:synced_at]},
        conflict_target: [:account_id, :membership_id]
      )
    end

    membership
  end

end
