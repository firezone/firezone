defmodule Portal.Repo.Migrations.CreateIruDeviceInventory do
  use Ecto.Migration

  def up do
    create table(:iru_posture_providers, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :id,
        references(:posture_providers,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      # The tenant lives at https://<subdomain>.api.kandji.io, or
      # https://<subdomain>.api.eu.kandji.io in the EU, so the pair identifies it.
      add(:subdomain, :string, null: false)
      add(:region, :string, null: false)
      add(:api_token, :string, null: false)

      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:iru_posture_providers, [:account_id, :region, :subdomain]))

    create table(:iru_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # Iru's device_id. Unique per tenant and stable for the life of the
      # enrollment, so it is the key rather than an id of our own.
      add(:iru_id, :string, null: false, primary_key: true)

      add(
        :posture_provider_id,
        references(:posture_providers,
          column: :id,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false
      )

      # /api/v1/devices
      add(:device_name, :string)
      add(:model, :string)
      add(:serial_number, :citext)
      add(:platform, :string)
      add(:os_version, :string)
      add(:supplemental_build_version, :string)
      add(:supplemental_os_version_extra, :string)
      add(:last_check_in_at, :timestamptz)
      add(:user_id, :string)
      add(:user_name, :string)
      add(:user_email, :string)
      add(:user_is_archived, :boolean)
      add(:asset_tag, :string)
      add(:blueprint_id, :string)
      add(:blueprint_name, :string)
      add(:mdm_enabled, :boolean)
      add(:agent_installed, :boolean)
      add(:agent_version, :string)
      add(:is_missing, :boolean)
      add(:is_removed, :boolean)
      add(:first_enrolled_at, :timestamptz)
      add(:last_enrolled_at, :timestamptz)
      add(:lost_mode_status, :string)
      add(:tags, {:array, :string})

      # /api/v1/prism/device_information
      add(:device_family, :string)
      add(:device_capacity_gb, :float)
      add(:host_name, :string)
      add(:local_hostname, :string)
      add(:apple_silicon, :boolean)
      add(:model_name, :string)
      add(:model_identifier, :string)
      add(:shared_ipad, :boolean)
      add(:cellular_technology, :string)
      add(:data_roaming, :boolean)
      add(:hotspot, :boolean)
      add(:os_build, :string)
      add(:os_name, :string)
      add(:display_os_version, :string)
      add(:inventory_collected_at, :timestamptz)

      # /api/v1/prism/filevault
      add(:filevault_enabled, :boolean)
      add(:filevault_key_type, :string)
      add(:filevault_key_escrowed, :boolean)
      add(:filevault_regeneration_needed, :boolean)
      add(:filevault_key_rotation_scheduled_at, :timestamptz)
      add(:filevault_collected_at, :timestamptz)

      # /api/v1/prism/application_firewall
      add(:firewall_enabled, :boolean)
      add(:firewall_block_all_incoming, :boolean)
      add(:firewall_logging, :boolean)
      add(:firewall_logging_option, :string)
      add(:firewall_stealth_mode, :boolean)
      add(:firewall_version, :string)
      add(:firewall_allow_signed_applications, :boolean)
      add(:firewall_unloading, :boolean)
      add(:firewall_collected_at, :timestamptz)

      # /api/v1/prism/gatekeeper_and_xprotect
      add(:gatekeeper_enabled, :boolean)
      add(:gatekeeper_trusted_developers, :boolean)
      add(:gatekeeper_version, :string)
      add(:gatekeeper_opaque_version, :string)
      add(:xprotect_version, :string)
      add(:malware_removal_tool_version, :string)
      add(:gatekeeper_collected_at, :timestamptz)

      # /api/v1/prism/startup_settings
      add(:sip_enabled, :boolean)
      add(:ssv_enabled, :boolean)
      add(:bootstrap_token_auth, :boolean)
      add(:bootstrap_token_escrowed, :boolean)
      add(:kext_requires_bootstrap_token, :boolean)
      add(:software_update_requires_bootstrap_token, :boolean)
      add(:external_boot_level, :string)
      add(:secure_boot_level, :string)
      add(:any_signed_os, :boolean)
      add(:mdm_manages_kext, :boolean)
      add(:user_manages_kext, :boolean)
      add(:startup_settings_collected_at, :timestamptz)

      # /api/v1/prism/activation_lock
      add(:activation_lock_supported, :boolean)
      add(:activation_lock_allowed_while_supervised, :boolean)
      add(:device_activation_lock_enabled, :boolean)
      add(:user_activation_lock_enabled, :boolean)
      add(:activation_lock_bypass_code_failed, :boolean)
      add(:activation_lock_collected_at, :timestamptz)

      add(:synced_at, :timestamptz, null: false)

      timestamps()
    end

    # Matches the REST list endpoint's cursor order so a page is an index range
    # scan rather than a sort of the whole account.
    create(index(:iru_devices, [:account_id, :inserted_at, :iru_id]))

    create(
      index(:iru_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :iru_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop(table(:iru_devices))
    drop(table(:iru_posture_providers))

    # The shared rows outlive the table they point at, and the migration before
    # this one restores a type constraint that does not allow them.
    execute("DELETE FROM posture_providers WHERE type = 'iru'")
  end
end
