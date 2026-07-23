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
      hostname: device.hostname,
      last_attested_device_serial: device.last_attested_device_serial,
      last_attested_device_uuid: device.last_attested_device_uuid,
      last_attested_mdm_device_id: device.last_attested_mdm_device_id,
      last_attested_cert_serial: device.last_attested_cert_serial,
      last_attested_cert_fingerprint: device.last_attested_cert_fingerprint,
      verified_at: device.verified_at,
      public_key: device.public_key,
      last_seen_at: device.last_seen_at,
      last_seen_version: device.last_seen_version,
      last_seen_user_agent: device.last_seen_user_agent,
      last_seen_remote_ip: device.last_seen_remote_ip,
      last_seen_remote_ip_location_region: device.last_seen_remote_ip_location_region,
      last_seen_remote_ip_location_city: device.last_seen_remote_ip_location_city,
      last_seen_remote_ip_location_lat: device.last_seen_remote_ip_location_lat,
      last_seen_remote_ip_location_lon: device.last_seen_remote_ip_location_lon,
      created_at: device.inserted_at,
      updated_at: device.updated_at
    }
  end
end
