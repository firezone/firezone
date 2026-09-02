defmodule PortalAPI.Schemas.IntuneDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    # Exposure is an explicit allowlist: a newly synced column must be added to
    # @exposed or @internal before it compiles. Property types stay derived.
    # The device table mirrors the Microsoft Graph managedDevice resource field
    # for field, so the documented properties are derived from the Ecto schema.
    # A newly synced field cannot end up in the database but missing here.
    @required [:account_id, :posture_provider_id, :intune_id, :synced_at]

    @exposed [
                :account_id,
                :intune_id,
                :posture_provider_id,
                :device_name,
                :managed_device_name,
                :serial_number,
                :entra_device_id,
                :enrollment_profile_name,
                :device_category_display_name,
                :user_id,
                :user_principal_name,
                :user_display_name,
                :email_address,
                :operating_system,
                :os_version,
                :model,
                :manufacturer,
                :imei,
                :meid,
                :iccid,
                :udid,
                :phone_number,
                :subscriber_carrier,
                :wifi_mac_address,
                :ethernet_mac_address,
                :android_security_patch_level,
                :total_storage_space_bytes,
                :free_storage_space_bytes,
                :physical_memory_bytes,
                :compliance_state,
                :management_state,
                :management_agent,
                :managed_device_owner_type,
                :device_enrollment_type,
                :device_registration_state,
                :partner_reported_threat_state,
                :jail_broken,
                :is_encrypted,
                :is_supervised,
                :entra_registered,
                :require_user_enrollment_approval,
                :notes,
                :eas_activated,
                :eas_device_id,
                :eas_activated_at,
                :exchange_access_state,
                :exchange_access_state_reason,
                :exchange_last_successful_sync_at,
                :config_manager_inventory,
                :config_manager_modern_apps,
                :config_manager_resource_access,
                :config_manager_device_configuration,
                :config_manager_compliance_policy,
                :config_manager_windows_update_for_business,
                :attestation_last_update_date_time,
                :attestation_content_namespace_url,
                :attestation_status,
                :attestation_content_version,
                :attestation_issued_at,
                :attestation_identity_key,
                :attestation_reset_count,
                :attestation_restart_count,
                :attestation_data_execution_policy,
                :attestation_bit_locker_status,
                :attestation_boot_manager_version,
                :attestation_code_integrity_check_version,
                :attestation_secure_boot,
                :attestation_boot_debugging,
                :attestation_operating_system_kernel_debugging,
                :attestation_code_integrity,
                :attestation_test_signing,
                :attestation_safe_mode,
                :attestation_windows_pe,
                :attestation_early_launch_anti_malware_driver_protection,
                :attestation_virtual_secure_mode,
                :attestation_pcr_hash_algorithm,
                :attestation_boot_app_security_version,
                :attestation_boot_manager_security_version,
                :attestation_tpm_version,
                :attestation_pcr0,
                :attestation_secure_boot_config_policy_fingerprint,
                :attestation_code_integrity_policy,
                :attestation_boot_revision_list_info,
                :attestation_operating_system_rev_list_info,
                :attestation_health_status_mismatch_info,
                :attestation_supported_status,
                :device_action_results,
                :enrolled_at,
                :last_sync_at,
                :compliance_grace_period_expiration_at,
                :management_certificate_expires_at,
                :synced_at,
                :inserted_at,
                :updated_at
             ]
    @internal []

    PortalAPI.Schemas.Object.assert_classified!(Portal.Intune.Device, @exposed, @internal)

    @properties Map.new(@exposed, fn field ->
                  nullable = field not in @required

                  schema =
                    case Portal.Intune.Device.__schema__(:type, field) do
                      :binary_id -> %Schema{type: :string, format: :uuid, nullable: nullable}
                      :string -> %Schema{type: :string, nullable: nullable}
                      :boolean -> %Schema{type: :boolean, nullable: nullable}
                      :integer -> %Schema{type: :integer, nullable: nullable}
                      :utc_datetime_usec -> %Schema{type: :string, format: :"date-time", nullable: nullable}
                      :map -> %Schema{type: :object, additionalProperties: true, nullable: nullable}
                      {:array, :map} -> %Schema{type: :array, items: %Schema{type: :object}, nullable: nullable}
                    end

                  {field, schema}
                end)

    object(%{
      title: "IntuneDevice",
      description: "Device synced from Microsoft Intune",
      type: :object,
      properties: @properties
    })
  end

  defmodule Response do
    use PortalAPI.Schemas.Object

    object(%{
      title: "IntuneDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.IntuneDevice.Schema}
    })
  end

  defmodule ListResponse do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.PaginationMetadata

    object(%{
      title: "IntuneDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.IntuneDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
