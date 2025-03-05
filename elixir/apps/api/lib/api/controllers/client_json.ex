defmodule API.ClientJSON do
  alias API.Pagination
  alias Domain.Clients

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

  defp data(%Clients.Client{} = client) do
    %{
      id: client.id,
      external_id: client.external_id,
      actor_id: client.actor_id,
      name: client.name,
      ipv4: client.ipv4,
      ipv6: client.ipv6,
      online: client.online?,
      last_seen_user_agent: client.last_seen_user_agent,
      last_seen_remote_ip: client.last_seen_remote_ip,
      last_seen_remote_ip_location_region: client.last_seen_remote_ip_location_region,
      last_seen_remote_ip_location_city: client.last_seen_remote_ip_location_city,
      last_seen_remote_ip_location_lat: client.last_seen_remote_ip_location_lat,
      last_seen_remote_ip_location_lon: client.last_seen_remote_ip_location_lon,
      last_seen_version: client.last_seen_version,
      last_seen_at: client.last_seen_at,
      device_serial: client.device_serial,
      device_uuid: client.device_uuid,
      identifier_for_vendor: client.identifier_for_vendor,
      firebase_installation_id: client.firebase_installation_id,
      verified_at: client.verified_at,
      verified_by: client.verified_by,
      verified_by_actor_id: client.verified_by_actor_id,
      verified_by_identity_id: client.verified_by_identity_id,
      created_at: client.inserted_at,
      updated_at: client.updated_at
    }
  end
end
