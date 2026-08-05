defmodule PortalAPI.Schemas.IntuneDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntuneDevice",
      description: "Device synced from Microsoft Intune",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        device_integration_id: %Schema{type: :string, format: :uuid},
        device_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Linked Firezone device connection record"
        },
        intune_id: %Schema{type: :string, description: "Intune managedDevice ID"},
        device_name: %Schema{type: :string, nullable: true},
        managed_device_name: %Schema{type: :string, nullable: true},
        serial_number: %Schema{type: :string, nullable: true},
        entra_device_id: %Schema{type: :string, nullable: true},
        user_id: %Schema{type: :string, nullable: true},
        user_principal_name: %Schema{type: :string, nullable: true},
        user_display_name: %Schema{type: :string, nullable: true},
        email_address: %Schema{type: :string, nullable: true},
        operating_system: %Schema{type: :string, nullable: true},
        os_version: %Schema{type: :string, nullable: true},
        model: %Schema{type: :string, nullable: true},
        manufacturer: %Schema{type: :string, nullable: true},
        compliance_state: %Schema{type: :string, nullable: true},
        management_agent: %Schema{type: :string, nullable: true},
        managed_device_owner_type: %Schema{type: :string, nullable: true},
        device_enrollment_type: %Schema{type: :string, nullable: true},
        device_registration_state: %Schema{type: :string, nullable: true},
        partner_reported_threat_state: %Schema{type: :string, nullable: true},
        jail_broken: %Schema{type: :string, nullable: true},
        is_encrypted: %Schema{type: :boolean, nullable: true},
        is_supervised: %Schema{type: :boolean, nullable: true},
        enrolled_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_sync_at: %Schema{type: :string, format: :"date-time", nullable: true},
        compliance_grace_period_expiration_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true
        },
        attributes: %Schema{type: :object, additionalProperties: true},
        synced_at: %Schema{type: :string, format: :"date-time"},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :account_id, :device_integration_id, :intune_id, :attributes, :synced_at]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "IntuneDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.IntuneDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "IntuneDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.IntuneDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
