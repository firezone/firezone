defmodule PortalAPI.PoolMemberJSON do
  alias PortalAPI.Pagination
  alias Portal.Device

  @doc """
  Renders a list of Clients belonging to a device pool.
  """
  def index(%{clients: clients, metadata: metadata}) do
    %{
      data: Enum.map(clients, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Renders the pool's membership as a list of Client IDs, after an update.
  """
  def members(%{device_ids: device_ids}) do
    %{data: %{device_ids: device_ids}}
  end

  defp data(%Device{} = device) do
    %{
      id: device.id,
      name: device.name,
      last_seen_at: device.last_seen_at
    }
  end
end
