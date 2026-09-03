defmodule PortalAPI.PoolMemberJSON do
  PortalAPI.JSON.verify!(__MODULE__, Portal.Device, PortalAPI.Schemas.PoolMember.Schema,
    internal: [
      :account_id,
      :actor_id,
      :attested?,
      :client_token_id,
      :device_serial,
      :device_uuid,
      :firebase_installation_id,
      :firezone_id,
      :firezone_id_merged?,
      :gateway_token_id,
      :gateway_token_rotated_at,
      :hostname,
      :identifier_for_vendor,
      :inserted_at,
      :ipv4,
      :ipv6,
      :last_attested_at,
      :last_attested_cert_fingerprint,
      :last_attested_cert_issuer,
      :last_attested_cert_serial,
      :last_attested_device_serial,
      :last_attested_device_uuid,
      :last_attested_mdm_device_id,
      :last_seen_remote_ip,
      :last_seen_remote_ip_location_city,
      :last_seen_remote_ip_location_lat,
      :last_seen_remote_ip_location_lon,
      :last_seen_remote_ip_location_region,
      :last_seen_user_agent,
      :last_seen_version,
      :online?,
      :psk_base,
      :public_key,
      :site_id,
      :type,
      :updated_at,
      :verified_at
    ]
  )

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

  defp data(%Device{} = device), do: PortalAPI.JSON.render(device, PortalAPI.Schemas.PoolMember.Schema)
end
