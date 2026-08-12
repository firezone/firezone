defmodule PortalAPI.Schemas.IntuneDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    # The device table mirrors the Microsoft Graph managedDevice resource field
    # for field, so the documented properties are derived from the Ecto schema.
    # A newly synced field cannot end up in the database but missing here.
    @required [:account_id, :device_integration_id, :intune_id, :synced_at]

    @properties Map.new(Portal.Intune.Device.__schema__(:fields), fn field ->
                  nullable = field not in @required

                  schema =
                    case Portal.Intune.Device.__schema__(:type, field) do
                      :binary_id -> %Schema{type: :string, format: :uuid, nullable: nullable}
                      :string -> %Schema{type: :string, nullable: nullable}
                      :boolean -> %Schema{type: :boolean, nullable: nullable}
                      :integer -> %Schema{type: :integer, nullable: nullable}
                      :utc_datetime_usec -> %Schema{type: :string, format: :"date-time", nullable: nullable}
                      :map -> %Schema{type: :object, additionalProperties: true, nullable: nullable}
                      {:array, :map} -> %Schema{type: :array, items: %Schema{type: :object}, nullable: nullable}
                    end

                  {field, schema}
                end)

    OpenApiSpex.schema(%{
      title: "IntuneDevice",
      description: "Device synced from Microsoft Intune",
      type: :object,
      properties: @properties,
      required: @required
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
