defmodule PortalAPI.Schemas.IruDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    # The device table mirrors what Iru reports for a device, so the documented
    # properties are derived from the Ecto schema. A newly synced field cannot
    # end up in the database but missing here.
    @required [:account_id, :posture_provider_id, :iru_id, :synced_at]

    @properties Map.new(Portal.Iru.Device.__schema__(:fields), fn field ->
                  nullable = field not in @required

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
      required: @required
    })
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
