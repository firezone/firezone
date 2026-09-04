defmodule PortalAPI.Schemas.SentinelOneDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @not_null [:account_id, :posture_provider_id, :uuid, :synced_at]

    # Property types come from the Ecto schema; the field list is explicit so a
    # newly synced column is published only once it is added here.
    @fields [
      :account_id,
      :uuid,
      :posture_provider_id,
      :source_created_at,
      :source_updated_at,
      :group_updated_at,
      :policy_updated_at,
      :sentinelone_account_id,
      :account_name,
      :site_id,
      :site_name,
      :group_id,
      :group_name,
      :sentinelone_id,
      :agent_version,
      :network_interfaces,
      :domain,
      :computer_name,
      :os_name,
      :os_revision,
      :os_arch,
      :os_username,
      :os_start_time,
      :os_type,
      :total_memory,
      :model_name,
      :machine_type,
      :cpu_id,
      :cpu_count,
      :core_count,
      :external_ip,
      :group_ip,
      :active_threats,
      :infected,
      :threat_reboot_required,
      :last_active_at,
      :is_active,
      :is_up_to_date,
      :network_status,
      :registered_at,
      :is_pending_uninstall,
      :is_uninstalled,
      :is_decommissioned,
      :encrypted_applications,
      :last_logged_in_user_name,
      :ad_last_user_distinguished_name,
      :ad_last_user_member_of,
      :ad_computer_distinguished_name,
      :ad_computer_member_of,
      :ad_user_principal_name,
      :ad_mail,
      :scan_status,
      :scan_started_at,
      :scan_finished_at,
      :scan_aborted_at,
      :full_disk_scan_updated_at,
      :mitigation_mode,
      :mitigation_mode_suspicious,
      :user_actions_needed,
      :missing_permissions,
      :console_migration_status,
      :apps_vulnerability_status,
      :in_remote_shell_session,
      :allow_remote_shell,
      :locations,
      :location_type,
      :external_id,
      :serial_number,
      :machine_sid,
      :installer_type,
      :ranger_version,
      :ranger_status,
      :last_ip_to_management,
      :operational_state,
      :operational_state_expires_at,
      :remote_profiling_state,
      :remote_profiling_state_expires_at,
      :network_quarantine_enabled,
      :firewall_enabled,
      :location_enabled,
      :cloud_providers,
      :storage_type,
      :storage_name,
      :detection_state,
      :first_full_mode_at,
      :tags,
      :show_alert_icon,
      :last_successful_scan_at,
      :proxy_console,
      :proxy_deep_visibility,
      :proxy_pac_file_usage,
      :proxy_method,
      :proxy_console_address,
      :proxy_deep_visibility_address,
      :protected_pods_count,
      :protected_containers_count,
      :protected_tasks_count,
      :has_containerized_workload,
      :is_ad_connector,
      :is_hyper_automate,
      :active_protection,
      :synced_at,
      :inserted_at,
      :updated_at
    ]

    @properties Map.new(@fields, fn field ->
                  nullable = field not in @not_null

                  schema =
                    case Portal.SentinelOne.Device.__schema__(:type, field) do
                      :binary_id ->
                        %Schema{type: :string, format: :uuid, nullable: nullable}

                      :string ->
                        %Schema{type: :string, nullable: nullable}

                      Portal.Types.IP ->
                        %Schema{type: :string, nullable: nullable}

                      :boolean ->
                        %Schema{type: :boolean, nullable: nullable}

                      :integer ->
                        %Schema{type: :integer, nullable: nullable}

                      :map ->
                        %Schema{type: :object, nullable: nullable, additionalProperties: true}

                      :utc_datetime_usec ->
                        %Schema{type: :string, format: :"date-time", nullable: nullable}

                      {:array, :string} ->
                        %Schema{
                          type: :array,
                          items: %Schema{type: :string},
                          nullable: nullable
                        }

                      {:array, :map} ->
                        %Schema{
                          type: :array,
                          items: %Schema{type: :object},
                          nullable: nullable
                        }
                    end

                  {field, schema}
                end)

    @derive {PortalAPI.JSON.Encoder, for: Portal.SentinelOne.Device}
    OpenApiSpex.schema(%{
      title: "SentinelOneDevice",
      description: "Endpoint agent synced from SentinelOne",
      type: :object,
      properties: @properties,
      required: @fields
    })
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SentinelOneDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SentinelOneDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SentinelOneDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.SentinelOneDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
