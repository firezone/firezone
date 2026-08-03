defmodule PortalAPI.IntuneDeviceJSON do
  alias Portal.Intune
  alias PortalAPI.Pagination

  def index(%{devices: devices, metadata: metadata}) do
    %{data: Enum.map(devices, &data/1), metadata: Pagination.metadata(metadata)}
  end

  def show(%{device: device}), do: %{data: data(device)}

  defp data(%Intune.Device{} = device) do
    %{
      id: device.id,
      account_id: device.account_id,
      device_integration_id: device.device_integration_id,
      device_id: device.device_id,
      intune_id: device.intune_id,
      device_name: device.device_name,
      managed_device_name: device.managed_device_name,
      serial_number: device.serial_number,
      entra_device_id: device.entra_device_id,
      user_id: device.user_id,
      user_principal_name: device.user_principal_name,
      user_display_name: device.user_display_name,
      email_address: device.email_address,
      operating_system: device.operating_system,
      os_version: device.os_version,
      model: device.model,
      manufacturer: device.manufacturer,
      compliance_state: device.compliance_state,
      management_agent: device.management_agent,
      managed_device_owner_type: device.managed_device_owner_type,
      device_enrollment_type: device.device_enrollment_type,
      device_registration_state: device.device_registration_state,
      partner_reported_threat_state: device.partner_reported_threat_state,
      jail_broken: device.jail_broken,
      is_encrypted: device.is_encrypted,
      is_supervised: device.is_supervised,
      enrolled_at: device.enrolled_at,
      last_sync_at: device.last_sync_at,
      compliance_grace_period_expiration_at: device.compliance_grace_period_expiration_at,
      attributes: device.attributes,
      synced_at: device.synced_at,
      inserted_at: device.inserted_at,
      updated_at: device.updated_at
    }
  end
end
