defmodule PortalAPI.ClientJSON do
  alias PortalAPI.Pagination
  alias Portal.Client

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

  defp data(%Client{} = client) do
    %{
      id: client.id,
      external_id: client.external_id,
      actor_id: client.actor_id,
      name: client.name,
      ipv4: client.ipv4_address.address,
      ipv6: client.ipv6_address.address,
      online: client.online?,
      device_serial: client.device_serial,
      device_uuid: client.device_uuid,
      identifier_for_vendor: client.identifier_for_vendor,
      firebase_installation_id: client.firebase_installation_id,
      verified_at: client.verified_at,
      created_at: client.inserted_at,
      updated_at: client.updated_at
    }
  end
end
