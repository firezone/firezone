defmodule PortalAPI.Schemas.SentinelOneDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @required [:account_id, :posture_provider_id, :uuid, :synced_at]
    @public_fields Portal.SentinelOne.Device.__schema__(:fields) -- [:license_key]

    @properties Map.new(@public_fields, fn field ->
                  nullable = field not in @required

                  schema =
                    case Portal.SentinelOne.Device.__schema__(:type, field) do
                      :binary_id ->
                        %Schema{type: :string, format: :uuid, nullable: nullable}

                      :string ->
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

    OpenApiSpex.schema(%{
      title: "SentinelOneDevice",
      description: "Endpoint agent synced from SentinelOne",
      type: :object,
      properties: @properties,
      required: @required
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
