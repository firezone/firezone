defmodule PortalAPI.Schemas.GoogleEndpointDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @not_null [:account_id, :posture_provider_id, :google_id, :synced_at]

    # Property types come from the Ecto schema; the field list is explicit so a
    # newly synced column is published only once it is added here.
    @fields [
      :account_id,
      :google_id,
      :posture_provider_id,
      :device_id,
      :unified_device_id,
      :device_type,
      :owner_type,
      :management_state,
      :compromised_state,
      :encryption_state,
      :model,
      :manufacturer,
      :brand,
      :hostname,
      :os_version,
      :release_version,
      :build_number,
      :kernel_version,
      :baseband_version,
      :bootloader_version,
      :security_patch_at,
      :serial_number,
      :asset_tag,
      :imei,
      :meid,
      :network_operator,
      :wifi_mac_addresses,
      :other_accounts,
      :enabled_developer_options,
      :enabled_usb_debugging,
      :android_enabled_unknown_sources,
      :android_supports_work_profile,
      :android_owner_profile_account,
      :android_ownership_privilege,
      :android_verified_boot,
      :android_cts_profile_match,
      :android_verify_apps_enabled,
      :android_has_potentially_harmful_apps,
      :endpoint_verification_attributes,
      :registered_at,
      :last_sync_at,
      :synced_at,
      :inserted_at,
      :updated_at
    ]

    @properties Map.new(@fields, fn field ->
                  nullable = field not in @not_null

                  schema =
                    case Portal.GoogleEndpoint.Device.__schema__(:type, field) do
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

    @derive {PortalAPI.JSON.Encoder, for: Portal.GoogleEndpoint.Device}
    OpenApiSpex.schema(%{
      title: "GoogleEndpointDevice",
      description: "Device synced from Google Endpoint Management",
      type: :object,
      properties: @properties,
      required: @fields
    })
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GoogleEndpointDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.GoogleEndpointDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GoogleEndpointDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.GoogleEndpointDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
