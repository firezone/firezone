defmodule PortalAPI.Schemas.DefenderDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @not_null [:account_id, :posture_provider_id, :defender_id, :synced_at]

    # Property types come from the Ecto schema; the field list is explicit so a
    # newly synced column is published only once it is added here.
    @fields [
      :account_id,
      :defender_id,
      :posture_provider_id,
      :computer_dns_name,
      :entra_device_id,
      :entra_joined,
      :machine_tags,
      :os_platform,
      :version,
      :os_build,
      :os_processor,
      :os_architecture,
      :last_ip_address,
      :last_external_ip_address,
      :agent_version,
      :health_status,
      :onboarding_status,
      :managed_by,
      :managed_by_status,
      :risk_score,
      :exposure_level,
      :device_value,
      :rbac_group_id,
      :rbac_group_name,
      :is_potential_duplication,
      :merged_into_machine_id,
      :is_excluded,
      :exclusion_reason,
      :vm_id,
      :vm_cloud_provider,
      :vm_resource_id,
      :vm_subscription_id,
      :ip_addresses,
      :first_seen_at,
      :last_seen_at,
      :synced_at,
      :inserted_at,
      :updated_at
    ]

    @properties Map.new(@fields, fn field ->
                  nullable = field not in @not_null

                  schema =
                    case Portal.Defender.Device.__schema__(:type, field) do
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

    @derive {PortalAPI.JSON.Encoder, for: Portal.Defender.Device}
    OpenApiSpex.schema(%{
      title: "DefenderDevice",
      description: "Device synced from Microsoft Defender for Endpoint",
      type: :object,
      properties: @properties,
      required: @fields
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DefenderDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.DefenderDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "DefenderDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.DefenderDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
