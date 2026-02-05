defmodule Portal.Policies.Reconnect do
  @moduledoc """
  Reconnects orphaned policies to their groups after directory sync.

  When a group is deleted, policies have their group_id set to NULL
  but retain their group_idp_id. When the group is re-synced (with a
  new UUID but same idp_id), this module reconnects the policies.
  """

  alias __MODULE__.Database

  @doc """
  Reconnects orphaned policies for an account after directory sync.

  Finds policies where:
  - group_id IS NULL (orphaned)
  - group_idp_id matches a group's idp_id

  Returns the count of reconnected policies.
  """
  @spec reconnect_orphaned_policies(Ecto.UUID.t()) :: non_neg_integer()
  def reconnect_orphaned_policies(account_id) do
    now = DateTime.utc_now()
    orphaned_policies = Database.list_orphaned_policies(account_id)

    if Enum.empty?(orphaned_policies) do
      0
    else
      idp_ids = orphaned_policies |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      idp_id_to_group_id = Database.get_group_ids_by_idp_ids(account_id, idp_ids)

      Enum.reduce(orphaned_policies, 0, fn {policy_id, group_idp_id}, acc ->
        case Map.get(idp_id_to_group_id, group_idp_id) do
          nil -> acc
          group_id -> acc + Database.reconnect_policy(account_id, policy_id, group_id, now)
        end
      end)
    end
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Group
    alias Portal.Policy
    alias Portal.Safe

    def list_orphaned_policies(account_id) do
      from(p in Policy,
        where: p.account_id == ^account_id,
        where: is_nil(p.group_id),
        where: not is_nil(p.group_idp_id),
        select: {p.id, p.group_idp_id}
      )
      |> Safe.unscoped()
      |> Safe.all()
    end

    def get_group_ids_by_idp_ids(account_id, idp_ids) do
      from(g in Group,
        where: g.account_id == ^account_id,
        where: g.idp_id in ^idp_ids,
        select: {g.idp_id, g.id}
      )
      |> Safe.unscoped()
      |> Safe.all()
      |> Map.new()
    end

    def reconnect_policy(account_id, policy_id, group_id, now) do
      from(p in Policy,
        where: p.account_id == ^account_id,
        where: p.id == ^policy_id,
        update: [set: [group_id: ^group_id, updated_at: ^now]]
      )
      |> Safe.unscoped()
      |> Safe.update_all([])
      |> case do
        {1, _} -> 1
        _ -> 0
      end
    end
  end
end
