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
      entity_type: group.entity_type,
      directory_id: group.directory_id,
      idp_id: group.idp_id,
      last_synced_at: group.last_synced_at,
      inserted_at: group.inserted_at,
      updated_at: group.updated_at
    }
  end
end
