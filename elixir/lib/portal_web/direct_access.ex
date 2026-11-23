defmodule PortalWeb.DirectAccess do
  @moduledoc """
  Gives people access to one resource without making a group first.

  Behind the scenes the people go into a group that belongs to the resource
  (`groups.resource_id`), and that group gets one policy for the resource. The
  portal makes the group on the first grant and deletes it after the last
  person is removed. Deleting the resource deletes the group too.

  These groups are never listed as groups. Show their members as people
  wherever the resource's access is shown.
  """
  alias __MODULE__.Database
  alias Portal.Authentication.Subject

  @doc "Whether `group` holds the people given direct access to a resource."
  @spec direct_group?(Portal.Group.t() | map()) :: boolean()
  def direct_group?(%{resource_id: resource_id}) when is_binary(resource_id), do: true
  def direct_group?(_group), do: false

  @doc "The people given direct access to `resource`, ordered by name."
  @spec list_people(Portal.Resource.t(), Subject.t()) :: [Portal.Actor.t()]
  def list_people(resource, %Subject{} = subject) do
    Database.list_people(resource.id, subject)
  end

  @doc "The direct-access group of `resource` with its policy, or nil."
  @spec get_group(Portal.Resource.t(), Subject.t()) :: Portal.Group.t() | nil
  def get_group(resource, %Subject{} = subject) do
    Database.get_group(resource.id, subject)
  end

  @doc """
  Gives each actor in `actor_ids` access to `resource`. Actors who already have
  direct access are skipped.
  """
  @spec grant(Portal.Resource.t(), [Ecto.UUID.t()], Subject.t()) ::
          {:ok, Portal.Group.t()} | {:error, term()}
  def grant(_resource, [], _subject), do: {:error, :no_actors}

  def grant(%Portal.Resource{} = resource, actor_ids, %Subject{} = subject) do
    Database.transact(fn ->
      with {:ok, group} <- ensure_group(resource, subject),
           {:ok, _policy} <- ensure_policy(group, resource, subject),
           :ok <- add_members(group, Enum.uniq(actor_ids), subject) do
        {:ok, group}
      end
    end)
  end

  @doc """
  Removes the direct access of one actor. The group goes away with its last member.
  """
  @spec revoke(Portal.Resource.t(), Ecto.UUID.t(), Subject.t()) :: :ok | {:error, term()}
  def revoke(%Portal.Resource{} = resource, actor_id, %Subject{} = subject) do
    Database.transact(fn ->
      with %Portal.Group{} = group <- Database.get_group(resource.id, subject) || {:error, :not_found},
           {:ok, _membership} <- Database.delete_membership(group.id, actor_id, subject) do
        maybe_delete_group(group, resource, subject)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_delete_group(group, resource, subject) do
    if Database.count_members(group.id, subject) == 0 do
      delete_group(group, resource, subject)
    else
      {:ok, :ok}
    end
  end

  # Policies outlive a deleted group (group_id is set to null so directory groups
  # can reconnect), so the policy is deleted first.
  defp delete_group(group, resource, subject) do
    with {:ok, _policy} <- delete_policy(group, resource, subject),
         {:ok, _group} <- Database.delete_group(group, subject) do
      {:ok, :ok}
    end
  end

  defp delete_policy(group, resource, subject) do
    case Database.get_policy(group.id, resource.id, subject) do
      nil -> {:ok, nil}
      policy -> Database.delete_policy(policy, subject)
    end
  end

  defp ensure_group(resource, subject) do
    case Database.get_group(resource.id, subject) do
      %Portal.Group{} = group -> {:ok, group}
      nil -> Database.insert_group(resource, subject)
    end
  end

  defp ensure_policy(group, resource, subject) do
    case Database.get_policy(group.id, resource.id, subject) do
      %Portal.Policy{} = policy -> {:ok, policy}
      nil -> Database.insert_policy(group.id, resource.id, subject)
    end
  end

  defp add_members(group, actor_ids, subject) do
    existing = MapSet.new(Database.member_ids(group.id, subject))

    actor_ids
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.reduce_while(:ok, fn actor_id, :ok ->
      case Database.insert_membership(group.id, actor_id, subject) do
        {:ok, _membership} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defmodule Database do
    import Ecto.Query
    import Ecto.Changeset
    alias Portal.Safe

    def transact(fun), do: Safe.transact(fun)

    def get_group(resource_id, subject) do
      from(g in Portal.Group, where: g.resource_id == ^resource_id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def list_people(resource_id, subject) do
      from(a in Portal.Actor,
        join: m in Portal.Membership,
        on: m.actor_id == a.id and m.account_id == a.account_id,
        join: g in Portal.Group,
        on: g.id == m.group_id and g.account_id == m.account_id,
        where: g.resource_id == ^resource_id,
        order_by: [asc: a.name]
      )
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def member_ids(group_id, subject) do
      from(m in Portal.Membership, where: m.group_id == ^group_id, select: m.actor_id)
      |> Safe.scoped(subject)
      |> Safe.all()
    end

    def count_members(group_id, subject) do
      from(m in Portal.Membership, where: m.group_id == ^group_id)
      |> Safe.scoped(subject)
      |> Safe.aggregate(:count)
    end

    def insert_group(resource, subject) do
      %Portal.Group{}
      |> change(%{
        name: group_name(resource),
        type: :static,
        resource_id: resource.id
      })
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def delete_group(group, subject) do
      group
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def get_policy(group_id, resource_id, subject) do
      from(p in Portal.Policy, where: p.group_id == ^group_id and p.resource_id == ^resource_id)
      |> Safe.scoped(subject)
      |> Safe.one()
    end

    def insert_policy(group_id, resource_id, subject) do
      %Portal.Policy{}
      |> change(%{group_id: group_id, resource_id: resource_id})
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def delete_policy(policy, subject) do
      policy
      |> Safe.scoped(subject)
      |> Safe.delete()
    end

    def insert_membership(group_id, actor_id, subject) do
      %Portal.Membership{}
      |> change(%{group_id: group_id, actor_id: actor_id})
      |> Safe.scoped(subject)
      |> Safe.insert()
    end

    def delete_membership(group_id, actor_id, subject) do
      from(m in Portal.Membership, where: m.group_id == ^group_id and m.actor_id == ^actor_id)
      |> Safe.scoped(subject)
      |> Safe.one()
      |> case do
        nil -> {:error, :not_found}
        membership -> membership |> Safe.scoped(subject) |> Safe.delete()
      end
    end

    # Group names are unique per account, and an admin may already use this one.
    # The resource id keeps it unique; the name is never shown in the portal.
    defp group_name(resource) do
      "Direct access: #{String.slice(resource.name, 0, 200)} (#{String.slice(resource.id, 0, 8)})"
    end
  end
end
