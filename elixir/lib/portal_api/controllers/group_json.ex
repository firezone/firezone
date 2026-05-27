defmodule PortalAPI.GroupJSON do
  alias PortalAPI.Pagination
  alias Portal.Group

  @doc """
  Renders a list of Groups.
  """
  def index(%{groups: groups, metadata: metadata}) do
    %{
      data: Enum.map(groups, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Group
  """
  def show(%{group: group}) do
    %{data: data(group)}
  end

  defp data(%Group{} = group) do
    %{
      id: group.id,
      name: group.name,
      email: group.email,
      entity_type: group.entity_type,
      directory_id: group.directory_id,
      idp_id: group.idp_id,
      synced_at: synced_at_from_state(group.sync_state),
      inserted_at: group.inserted_at,
      updated_at: group.updated_at
    }
  end

  defp synced_at_from_state(%Portal.GroupSyncState{synced_at: t}), do: t
  defp synced_at_from_state(nil), do: nil
end
