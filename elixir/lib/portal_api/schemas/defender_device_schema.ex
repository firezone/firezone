defmodule PortalAPI.Schemas.DefenderDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    # The device table mirrors the Defender for Endpoint machine resource field
    # for field, so the documented properties are derived from the Ecto schema.
    # A newly synced field cannot end up in the database but missing here.
    @required [:account_id, :posture_provider_id, :defender_id, :synced_at]

    @properties Map.new(Portal.Defender.Device.__schema__(:fields), fn field ->
                  nullable = field not in @required

                  schema =
                    case Portal.Defender.Device.__schema__(:type, field) do
                      :binary_id ->
                        %Schema{type: :string, format: :uuid, nullable: nullable}

                      :string ->
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

    OpenApiSpex.schema(%{
      title: "DefenderDevice",
      description: "Device synced from Microsoft Defender for Endpoint",
      type: :object,
      properties: @properties,
      required: @required
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
