defmodule PortalAPI.Schemas.IruDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    @behaviour PortalAPI.Schema

    require OpenApiSpex
    alias OpenApiSpex.Schema

    @not_null [:account_id, :posture_provider_id, :iru_id, :synced_at]

    # Property types come from the Ecto schema; the field list is explicit so a
    # newly synced column is published only once it is added here.
    @fields [
      :account_id,
      :iru_id,
      :posture_provider_id,
      :device_name,
      :model,
      :serial_number,
      :platform,
      :os_version,
      :supplemental_build_version,
      :supplemental_os_version_extra,
      :last_check_in_at,
      :user_id,
      :user_name,
      :user_email,
      :user_is_archived,
      :asset_tag,
      :blueprint_id,
      :blueprint_name,
      :mdm_enabled,
      :agent_installed,
      :agent_version,
      :is_missing,
      :is_removed,
      :first_enrolled_at,
      :last_enrolled_at,
      :lost_mode_status,
      :tags,
      :device_family,
      :device_capacity_gb,
      :host_name,
      :local_hostname,
      :apple_silicon,
      :model_name,
      :model_identifier,
      :shared_ipad,
      :cellular_technology,
      :data_roaming,
      :hotspot,
      :os_build,
      :os_name,
      :display_os_version,
      :inventory_collected_at,
      :filevault_enabled,
      :filevault_key_type,
      :filevault_key_escrowed,
      :filevault_regeneration_needed,
      :filevault_key_rotation_scheduled_at,
      :filevault_collected_at,
      :firewall_enabled,
      :firewall_block_all_incoming,
      :firewall_logging,
      :firewall_logging_option,
      :firewall_stealth_mode,
      :firewall_version,
      :firewall_allow_signed_applications,
      :firewall_unloading,
      :firewall_collected_at,
      :gatekeeper_enabled,
      :gatekeeper_trusted_developers,
      :gatekeeper_version,
      :gatekeeper_opaque_version,
      :xprotect_version,
      :malware_removal_tool_version,
      :gatekeeper_collected_at,
      :sip_enabled,
      :ssv_enabled,
      :bootstrap_token_auth,
      :bootstrap_token_escrowed,
      :kext_requires_bootstrap_token,
      :software_update_requires_bootstrap_token,
      :external_boot_level,
      :secure_boot_level,
      :any_signed_os,
      :mdm_manages_kext,
      :user_manages_kext,
      :startup_settings_collected_at,
      :activation_lock_supported,
      :activation_lock_allowed_while_supervised,
      :device_activation_lock_enabled,
      :user_activation_lock_enabled,
      :activation_lock_bypass_code_failed,
      :activation_lock_collected_at,
      :synced_at,
      :inserted_at,
      :updated_at
    ]

    @properties Map.new(@fields, fn field ->
                  nullable = field not in @not_null

                  schema =
                    case Portal.Iru.Device.__schema__(:type, field) do
                      :binary_id ->
                        %Schema{type: :string, format: :uuid, nullable: nullable}

                      :string ->
                        %Schema{type: :string, nullable: nullable}

                      :boolean ->
                        %Schema{type: :boolean, nullable: nullable}

                      :float ->
                        %Schema{type: :number, format: :float, nullable: nullable}

                      :utc_datetime_usec ->
                        %Schema{type: :string, format: :"date-time", nullable: nullable}

                      {:array, :string} ->
                        %Schema{
                          type: :array,
                          items: %Schema{type: :string},
                          nullable: nullable
                        }
                    end

                  {field, schema}
                end)

    OpenApiSpex.schema(%{
      title: "IruDevice",
      description: "Device synced from Iru (formerly Kandji)",
      type: :object,
      properties: @properties,
      required: @fields
    })

    @impl true
    def struct_module, do: Portal.Iru.Device
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IruDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.IruDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "IruDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.IruDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
