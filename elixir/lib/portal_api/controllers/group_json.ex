defmodule PortalAPI.GroupJSON do
  use PortalAPI.JSON,
    struct: Portal.Group,
    schema: PortalAPI.Schemas.Group.Schema,
    computed: [:synced_at],
    internal: [
      :account_id,
      :type
    ]

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
    render_fields(group, %{synced_at: synced_at_from_state(group.sync_state)})
  end

  defp synced_at_from_state(%Portal.GroupSyncState{synced_at: t}), do: t
  defp synced_at_from_state(nil), do: nil
end
