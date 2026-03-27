defmodule PortalAPI.ClientJSON do
  alias PortalAPI.Pagination
  alias Portal.Device

  @doc """
  Renders a list of Clients.
  """
  def index(%{clients: clients, metadata: metadata}) do
    %{
      data: Enum.map(clients, &data/1),
      metadata: Pagination.metadata(metadata)
    }
  end

  @doc """
  Render a single Client
  """
  def show(%{client: client}) do
    %{data: data(client)}
  end

  defp data(%Device{} = device) do
    %{
      id: device.id,
      firezone_id: device.firezone_id,
      actor_id: device.actor_id,
      name: device.name,
      ipv4: device.ipv4,
      ipv6: device.ipv6,
      online: device.online?,
      device_serial: device.device_serial,
      device_uuid: device.device_uuid,
      identifier_for_vendor: device.identifier_for_vendor,
      firebase_installation_id: device.firebase_installation_id,
      verified_at: device.verified_at,
      created_at: device.inserted_at,
      updated_at: device.updated_at
    }
  end
end
