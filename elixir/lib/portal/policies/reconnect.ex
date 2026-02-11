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

  Finds policies where group_id IS NULL and group_idp_id matches a
  group's idp_id, then restores the group_id in a single atomic query.

  Returns the count of reconnected policies.
  """
  @spec reconnect_orphaned_policies(Ecto.UUID.t()) :: non_neg_integer()
  def reconnect_orphaned_policies(account_id) do
    Database.reconnect_orphaned_policies(account_id)
  end

  defmodule Database do
    import Ecto.Query
    alias Portal.Group
    alias Portal.Policy
    alias Portal.Safe

    @spec reconnect_orphaned_policies(Ecto.UUID.t()) :: non_neg_integer()
    def reconnect_orphaned_policies(account_id) do
      now = DateTime.utc_now()

      {count, _} =
        from(p in Policy,
          join: g in Group,
          on: g.account_id == p.account_id and g.idp_id == p.group_idp_id,
          where: p.account_id == ^account_id,
          where: is_nil(p.group_id),
          where: not is_nil(p.group_idp_id),
          update: [set: [group_id: g.id, updated_at: ^now]]
        )
        |> Safe.unscoped()
        |> Safe.update_all([])

      count
    end
  end
end
