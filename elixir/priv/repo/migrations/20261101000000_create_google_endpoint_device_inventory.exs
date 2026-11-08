defmodule Portal.Repo.Migrations.CreateGoogleEndpointDeviceInventory do
  use Ecto.Migration

  def up do
    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check:
          "type IN ('intune', 'iru', 'defender', 'santa', 'sentinelone', 'sophos', 'google_endpoint')"
      )
    )

    create table(:google_endpoint_posture_providers, primary_key: false) do
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

      # Both come from the Google sign-in that verified the provider, never typed in.
      add(:impersonation_email, :string, null: false)
      add(:domain, :string, null: false)

      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:google_endpoint_posture_providers, [:account_id, :domain]))

    create table(:google_endpoint_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:google_id, :string, null: false, primary_key: true)

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

      # Device resource, Cloud Identity API v1 `GET /v1/devices`.
      add(:device_id, :string)
      add(:unified_device_id, :string)
      add(:device_type, :string)
      add(:owner_type, :string)
      add(:management_state, :string)
      add(:compromised_state, :string)
      add(:encryption_state, :string)
      add(:model, :string)
      add(:manufacturer, :string)
      add(:brand, :string)
      add(:hostname, :string)
      add(:os_version, :string)
      add(:release_version, :string)
      add(:build_number, :string)
      add(:kernel_version, :string)
      add(:baseband_version, :string)
      add(:bootloader_version, :string)
      add(:security_patch_at, :timestamptz)
      # Not every device reports one; personal phones usually do not.
      add(:serial_number, :string)
      add(:asset_tag, :string)
      add(:imei, :string)
      add(:meid, :string)
      add(:network_operator, :string)
      add(:wifi_mac_addresses, {:array, :string})
      add(:other_accounts, {:array, :string})
      add(:enabled_developer_options, :boolean)
      add(:enabled_usb_debugging, :boolean)
      add(:android_enabled_unknown_sources, :boolean)
      add(:android_supports_work_profile, :boolean)
      add(:android_owner_profile_account, :boolean)
      add(:android_ownership_privilege, :string)
      add(:android_verified_boot, :boolean)
      add(:android_cts_profile_match, :boolean)
      add(:android_verify_apps_enabled, :boolean)
      add(:android_has_potentially_harmful_apps, :boolean)
      add(:endpoint_verification_attributes, :map)
      add(:registered_at, :timestamptz)
      add(:last_sync_at, :timestamptz)

      add(:synced_at, :timestamptz, null: false)
      timestamps()
    end

    create(index(:google_endpoint_devices, [:account_id, :inserted_at, :google_id]))

    create(
      index(:google_endpoint_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :google_endpoint_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop(table(:google_endpoint_devices))
    drop(table(:google_endpoint_posture_providers))

    drop(constraint(:posture_providers, :type_must_be_valid))
    execute("DELETE FROM posture_providers WHERE type = 'google_endpoint'")

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender', 'santa', 'sentinelone', 'sophos')"
      )
    )
  end
end
