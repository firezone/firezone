defmodule PortalAPI.Schemas.SophosDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @not_null [:account_id, :posture_provider_id, :sophos_id, :synced_at]

    # Property types come from the Ecto schema; the field list is explicit so a
    # newly synced column is published only once it is added here.
    @fields [
      :account_id,
      :sophos_id,
      :posture_provider_id,
      :type,
      :sophos_tenant_id,
      :hostname,
      :health_overall,
      :health_threats_status,
      :health_services_status,
      :health_service_details,
      :os_is_server,
      :os_platform,
      :os_name,
      :os_major_version,
      :os_minor_version,
      :os_build,
      :ipv4_addresses,
      :ipv6_addresses,
      :mac_addresses,
      :group_id,
      :group_name,
      :group_hierarchy,
      :associated_person_id,
      :associated_person_name,
      :associated_person_via_login,
      :tamper_protection_supported,
      :tamper_protection_enabled,
      :assigned_products,
      :packages,
      :device_software,
      :last_seen_at,
      :last_os_update_at,
      :last_agent_update_at,
      :serial_number,
      :encryption_overall_status,
      :encryption_volumes,
      :lockdown_status,
      :tags,
      :online,
      :cloud_provider,
      :cloud_instance_id,
      :isolation_status,
      :isolation_admin_isolated,
      :isolation_self_isolated,
      :cloned,
      :synced_at,
      :inserted_at,
      :updated_at
    ]

    @properties Map.new(@fields, fn field ->
                  nullable = field not in @not_null

                  schema =
                    case Portal.Sophos.Device.__schema__(:type, field) do
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

    @derive {PortalAPI.JSON.Encoder, for: Portal.Sophos.Device}
    OpenApiSpex.schema(%{
      title: "SophosDevice",
      description: "Endpoint synced from Sophos Central",
      type: :object,
      properties: @properties,
      required: @fields
    })
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SophosDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SophosDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SophosDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.SophosDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
