defmodule Portal.IntuneFixtures do
  import Portal.AccountFixtures

  def intune_integration_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    account = Map.get(attrs, :account) || account_fixture()
    id = Map.get(attrs, :id, Ecto.UUID.generate())
    unique = System.unique_integer([:positive, :monotonic])

    parent =
      %Portal.DeviceIntegration{}
      |> Ecto.Changeset.change(%{id: id, account_id: account.id, type: :intune})
      |> Portal.DeviceIntegration.changeset()
      |> Portal.Repo.insert!()

    integration_attrs = %{
      id: id,
      account_id: account.id,
      name: Map.get(attrs, :name, "Microsoft Intune #{unique}"),
      tenant_id: Map.get(attrs, :tenant_id, Ecto.UUID.generate()),
      is_verified: Map.get(attrs, :is_verified, true),
      is_disabled: Map.get(attrs, :is_disabled, false),
      disabled_reason: Map.get(attrs, :disabled_reason),
      synced_at: Map.get(attrs, :synced_at),
      errored_at: Map.get(attrs, :errored_at),
      error_message: Map.get(attrs, :error_message)
    }

    %Portal.Intune.Integration{device_integration: parent}
    |> Ecto.Changeset.cast(integration_attrs, Map.keys(integration_attrs))
    |> Portal.Intune.Integration.changeset()
    |> Portal.Repo.insert!()
  end

  def intune_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})
    integration = Map.get(attrs, :integration) || intune_integration_fixture(attrs)
    unique = System.unique_integer([:positive, :monotonic])

    device_attrs = %{
      account_id: integration.account_id,
      device_integration_id: integration.id,
      device_id: Map.get(attrs, :device_id),
      intune_id: Map.get(attrs, :intune_id, "intune-device-#{unique}"),
      device_name: Map.get(attrs, :device_name, "Inventory Device #{unique}"),
      managed_device_name: Map.get(attrs, :managed_device_name),
      serial_number: Map.get(attrs, :serial_number, "INTUNE-SERIAL-#{unique}"),
      entra_device_id: Map.get(attrs, :entra_device_id, Ecto.UUID.generate()),
      user_id: Map.get(attrs, :user_id),
      user_principal_name: Map.get(attrs, :user_principal_name),
      user_display_name: Map.get(attrs, :user_display_name),
      email_address: Map.get(attrs, :email_address),
      operating_system: Map.get(attrs, :operating_system, "Windows"),
      os_version: Map.get(attrs, :os_version, "11"),
      model: Map.get(attrs, :model),
      manufacturer: Map.get(attrs, :manufacturer),
      compliance_state: Map.get(attrs, :compliance_state, "compliant"),
      management_agent: Map.get(attrs, :management_agent, "mdm"),
      managed_device_owner_type: Map.get(attrs, :managed_device_owner_type),
      device_enrollment_type: Map.get(attrs, :device_enrollment_type),
      device_registration_state: Map.get(attrs, :device_registration_state),
      partner_reported_threat_state: Map.get(attrs, :partner_reported_threat_state),
      jail_broken: Map.get(attrs, :jail_broken),
      is_encrypted: Map.get(attrs, :is_encrypted),
      is_supervised: Map.get(attrs, :is_supervised),
      enrolled_at: Map.get(attrs, :enrolled_at),
      last_sync_at: Map.get(attrs, :last_sync_at),
      compliance_grace_period_expiration_at:
        Map.get(attrs, :compliance_grace_period_expiration_at),
      synced_at:
        Map.get(attrs, :synced_at, DateTime.utc_now() |> DateTime.truncate(:microsecond)),
      attributes: Map.get(attrs, :attributes, %{"id" => "intune-device-#{unique}"})
    }

    %Portal.Intune.Device{}
    |> Portal.Intune.Device.changeset(device_attrs)
    |> Portal.Repo.insert!()
  end
end
