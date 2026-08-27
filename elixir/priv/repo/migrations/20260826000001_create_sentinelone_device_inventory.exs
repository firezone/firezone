defmodule Portal.Repo.Migrations.CreateSentinelOneDeviceInventory do
  use Ecto.Migration

  def up do
    drop(constraint(:posture_providers, :type_must_be_valid))

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender', 'santa', 'sentinelone')"
      )
    )

    create table(:sentinelone_posture_providers, primary_key: false) do
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

      add(:management_url, :string, null: false)
      # SentinelOne API tokens are JWT-shaped and can exceed varchar(255).
      add(:api_token, :text, null: false)

      add(:is_verified, :boolean, default: false, null: false)
      add(:is_disabled, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:synced_at, :timestamptz)
      add(:errored_at, :timestamptz)
      add(:error_message, :text)
      add(:error_email_count, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:sentinelone_posture_providers, [:account_id, :management_url]))

    create table(:sentinelone_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      # SentinelOne explicitly documents this value as the agent's universally
      # unique identifier, so it is the stable inventory identity.
      add(:uuid, :string, null: false, primary_key: true)

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

      # agents.schemas_AgentViewSchema_many_200, Management API v2.1.
      add(:source_created_at, :timestamptz)
      add(:source_updated_at, :timestamptz)
      add(:group_updated_at, :timestamptz)
      add(:policy_updated_at, :timestamptz)
      add(:sentinelone_account_id, :string)
      add(:account_name, :string)
      add(:site_id, :string)
      add(:site_name, :string)
      add(:group_id, :string)
      add(:group_name, :string)
      add(:license_key, :text)
      # SentinelOne's numeric API object ID is retained as telemetry, but is
      # not used as identity because its uniqueness scope is undocumented.
      add(:sentinelone_id, :string)
      add(:agent_version, :string)
      # Ecto's {:array, :map} is encoded as one JSON array in a jsonb column.
      add(:network_interfaces, :map)
      add(:domain, :string)
      add(:computer_name, :string)
      add(:os_name, :string)
      add(:os_revision, :string)
      add(:os_arch, :string)
      add(:os_username, :string)
      add(:os_start_time, :timestamptz)
      add(:os_type, :string)
      add(:total_memory, :bigint)
      add(:model_name, :string)
      add(:machine_type, :string)
      add(:cpu_id, :string)
      add(:cpu_count, :integer)
      add(:core_count, :integer)
      add(:external_ip, :string)
      add(:group_ip, :string)
      add(:active_threats, :integer)
      add(:infected, :boolean)
      add(:threat_reboot_required, :boolean)
      add(:last_active_at, :timestamptz)
      add(:is_active, :boolean)
      add(:is_up_to_date, :boolean)
      add(:network_status, :string)
      add(:registered_at, :timestamptz)
      add(:is_pending_uninstall, :boolean)
      add(:is_uninstalled, :boolean)
      add(:is_decommissioned, :boolean)
      add(:encrypted_applications, :boolean)
      add(:last_logged_in_user_name, :string)

      # activeDirectory
      add(:ad_last_user_distinguished_name, :text)
      add(:ad_last_user_member_of, {:array, :text})
      add(:ad_computer_distinguished_name, :text)
      add(:ad_computer_member_of, {:array, :text})
      add(:ad_user_principal_name, :string)
      add(:ad_mail, :string)

      add(:scan_status, :string)
      add(:scan_started_at, :timestamptz)
      add(:scan_finished_at, :timestamptz)
      add(:scan_aborted_at, :timestamptz)
      add(:full_disk_scan_updated_at, :timestamptz)
      add(:mitigation_mode, :string)
      add(:mitigation_mode_suspicious, :string)
      add(:user_actions_needed, {:array, :string})
      add(:missing_permissions, {:array, :string})
      add(:console_migration_status, :string)
      add(:apps_vulnerability_status, :string)
      add(:in_remote_shell_session, :boolean)
      add(:allow_remote_shell, :boolean)
      add(:locations, :map)
      add(:location_type, :string)
      add(:external_id, :string)
      add(:serial_number, :citext)
      add(:machine_sid, :string)
      add(:installer_type, :string)
      add(:ranger_version, :string)
      add(:ranger_status, :string)
      add(:last_ip_to_management, :string)
      add(:operational_state, :string)
      add(:operational_state_expires_at, :timestamptz)
      add(:remote_profiling_state, :string)
      add(:remote_profiling_state_expires_at, :timestamptz)
      add(:network_quarantine_enabled, :boolean)
      add(:firewall_enabled, :boolean)
      add(:location_enabled, :boolean)
      add(:cloud_providers, :map)
      add(:storage_type, :string)
      add(:storage_name, :string)
      add(:detection_state, :string)
      add(:first_full_mode_at, :timestamptz)
      # Only the documented `tags.sentinelone` list is stored.
      add(:tags, :map)
      add(:show_alert_icon, :boolean)
      add(:last_successful_scan_at, :timestamptz)

      # proxyStates
      add(:proxy_console, :boolean)
      add(:proxy_deep_visibility, :boolean)
      add(:proxy_pac_file_usage, :boolean)
      add(:proxy_method, :string)
      add(:proxy_console_address, :string)
      add(:proxy_deep_visibility_address, :string)

      # containerizedWorkloadCounts
      add(:protected_pods_count, :integer)
      add(:protected_containers_count, :integer)
      add(:protected_tasks_count, :integer)
      add(:has_containerized_workload, :boolean)
      add(:is_ad_connector, :boolean)
      add(:is_hyper_automate, :boolean)
      add(:active_protection, {:array, :string})

      add(:synced_at, :timestamptz, null: false)
      timestamps()
    end

    create(index(:sentinelone_devices, [:account_id, :inserted_at, :uuid]))

    create(
      index(:sentinelone_devices, [:account_id, :posture_provider_id, :synced_at],
        name: :sentinelone_devices_provider_synced_at_index
      )
    )
  end

  def down do
    drop(table(:sentinelone_devices))
    drop(table(:sentinelone_posture_providers))

    drop(constraint(:posture_providers, :type_must_be_valid))
    execute("DELETE FROM posture_providers WHERE type = 'sentinelone'")

    create(
      constraint(:posture_providers, :type_must_be_valid,
        check: "type IN ('intune', 'iru', 'defender', 'santa')"
      )
    )
  end
end
