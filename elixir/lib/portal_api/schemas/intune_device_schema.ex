defmodule PortalAPI.Schemas.IntuneDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    # The device table mirrors the Microsoft Graph managedDevice resource field
    # for field, so the documented properties are derived from the Ecto schema.
    # A newly synced field cannot end up in the database but missing here.
    @properties Map.new(Portal.Intune.Device.__schema__(:fields), fn field ->
                  schema =
                    case Portal.Intune.Device.__schema__(:type, field) do
                      :binary_id -> %Schema{type: :string, format: :uuid, nullable: true}
                      :string -> %Schema{type: :string, nullable: true}
                      :boolean -> %Schema{type: :boolean, nullable: true}
                      :integer -> %Schema{type: :integer, nullable: true}
                      :utc_datetime_usec -> %Schema{type: :string, format: :"date-time", nullable: true}
                      :map -> %Schema{type: :object, additionalProperties: true}
                      {:array, :map} -> %Schema{type: :array, items: %Schema{type: :object}}
                    end

                  {field, schema}
                end)

    OpenApiSpex.schema(%{
      title: "IntuneDevice",
      description: "Device synced from Microsoft Intune",
      type: :object,
      properties: @properties,
      required: [:account_id, :device_integration_id, :intune_id, :synced_at]
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
