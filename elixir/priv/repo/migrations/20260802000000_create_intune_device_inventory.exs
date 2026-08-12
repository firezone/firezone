defmodule Portal.Repo.Migrations.CreateIntuneDeviceInventory do
  use Ecto.Migration

  def up do
    create table(:device_integrations, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:type, :string, null: false)
    end

    create(
      constraint(:device_integrations, :type_must_be_valid,
        check: "type IN ('intune')"
      )
    )

    create(
      unique_index(:device_integrations, [:account_id, :type],
        name: :device_integrations_account_id_type_index
      )
    )

    create table(:intune_integrations, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :id,
        references(:device_integrations,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(:name, :string, null: false)
      add(:tenant_id, :string, null: false)
      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create table(:intune_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # Graph's managedDevice id. Unique per tenant and stable for the life of
      # the enrollment, so it is the key rather than an id of our own.
      add(:intune_id, :string, null: false, primary_key: true)

      add(
        :device_integration_id,
        references(:device_integrations,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:device_name, :string)
      add(:managed_device_name, :string)
      add(:serial_number, :citext)
      add(:entra_device_id, :string)
      add(:enrollment_profile_name, :string)
      add(:device_category_display_name, :string)

      # Assigned user
      add(:user_id, :string)
      add(:user_principal_name, :string)
      add(:user_display_name, :string)
      add(:email_address, :string)

      # Hardware
      add(:operating_system, :string)
      add(:os_version, :string)
      add(:model, :string)
      add(:manufacturer, :string)
      add(:imei, :string)
      add(:meid, :string)
      add(:iccid, :string)
      add(:udid, :string)
      add(:phone_number, :string)
      add(:subscriber_carrier, :string)
      add(:wifi_mac_address, :string)
      add(:ethernet_mac_address, :string)
      add(:android_security_patch_level, :string)
      add(:total_storage_space_bytes, :bigint)
      add(:free_storage_space_bytes, :bigint)
      add(:physical_memory_bytes, :bigint)

      # Management and posture
      add(:compliance_state, :string)
      add(:management_state, :string)
      add(:management_agent, :string)
      add(:managed_device_owner_type, :string)
      add(:device_enrollment_type, :string)
      add(:device_registration_state, :string)
      add(:partner_reported_threat_state, :string)
      add(:jail_broken, :string)
      add(:is_encrypted, :boolean)
      add(:is_supervised, :boolean)
      add(:entra_registered, :boolean)
      add(:require_user_enrollment_approval, :boolean)
      add(:notes, :text)

      # Exchange ActiveSync
      add(:eas_activated, :boolean)
      add(:eas_device_id, :string)
      add(:eas_activated_at, :timestamptz)
      add(:exchange_access_state, :string)
      add(:exchange_access_state_reason, :string)
      add(:exchange_last_successful_sync_at, :timestamptz)

      # Remote assistance
      add(:remote_assistance_session_url, :text)
      add(:remote_assistance_session_error_details, :text)

      # Configuration Manager co-management
      add(:config_manager_inventory, :boolean)
      add(:config_manager_modern_apps, :boolean)
      add(:config_manager_resource_access, :boolean)
      add(:config_manager_device_configuration, :boolean)
      add(:config_manager_compliance_policy, :boolean)
      add(:config_manager_windows_update_for_business, :boolean)

      # Windows device health attestation
      add(:attestation_last_update_date_time, :string)
      add(:attestation_content_namespace_url, :text)
      add(:attestation_status, :string)
      add(:attestation_content_version, :string)
      add(:attestation_issued_at, :timestamptz)
      add(:attestation_identity_key, :text)
      add(:attestation_reset_count, :integer)
      add(:attestation_restart_count, :integer)
      add(:attestation_data_execution_policy, :string)
      add(:attestation_bit_locker_status, :string)
      add(:attestation_boot_manager_version, :string)
      add(:attestation_code_integrity_check_version, :string)
      add(:attestation_secure_boot, :string)
      add(:attestation_boot_debugging, :string)
      add(:attestation_operating_system_kernel_debugging, :string)
      add(:attestation_code_integrity, :string)
      add(:attestation_test_signing, :string)
      add(:attestation_safe_mode, :string)
      add(:attestation_windows_pe, :string)
      add(:attestation_early_launch_anti_malware_driver_protection, :string)
      add(:attestation_virtual_secure_mode, :string)
      add(:attestation_pcr_hash_algorithm, :string)
      add(:attestation_boot_app_security_version, :string)
      add(:attestation_boot_manager_security_version, :string)
      add(:attestation_tpm_version, :string)
      add(:attestation_pcr0, :text)
      add(:attestation_secure_boot_config_policy_fingerprint, :text)
      add(:attestation_code_integrity_policy, :text)
      add(:attestation_boot_revision_list_info, :text)
      add(:attestation_operating_system_rev_list_info, :text)
      add(:attestation_health_status_mismatch_info, :text)
      add(:attestation_supported_status, :string)

      # deviceActionResults is the one collection-valued property on
      # managedDevice, so it cannot become a column of its own. `:map` is jsonb,
      # which stores the JSON array the schema reads back as {:array, :map}.
      # Declaring the array type here would give jsonb[], which is not the same.
      add(:device_action_results, :map)

      add(:enrolled_at, :timestamptz)
      add(:last_sync_at, :timestamptz)
      add(:compliance_grace_period_expiration_at, :timestamptz)
      add(:management_certificate_expires_at, :timestamptz)
      add(:synced_at, :timestamptz, null: false)

      timestamps()
    end

    # Matches the REST list endpoint's cursor order so a page is an index range
    # scan rather than a sort of the whole account.
    create(index(:intune_devices, [:account_id, :inserted_at, :intune_id]))
    create(index(:intune_devices, [:account_id, :device_integration_id, :synced_at]))
  end

  def down do
    drop(table(:intune_devices))
    drop(table(:intune_integrations))
    drop(table(:device_integrations))
  end
end
