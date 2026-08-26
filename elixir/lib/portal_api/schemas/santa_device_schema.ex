defmodule PortalAPI.Schemas.SantaDevice do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @required [:account_id, :id, :posture_provider_id, :santa_id, :synced_at]

    @properties Map.new(Portal.Santa.Device.__schema__(:fields), fn field ->
                  nullable = field not in @required

                  schema =
                    case Portal.Santa.Device.__schema__(:type, field) do
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
                    end

                  schema =
                    if field == :last_preflight_ip do
                      # workshop.v1.Host declares this field as bytes, which
                      # ProtoJSON represents as a base64-encoded string.
                      %{schema | format: :byte}
                    else
                      schema
                    end

                  {field, schema}
                end)

    OpenApiSpex.schema(%{
      title: "SantaDevice",
      description: "Santa host synced from North Pole Security Workshop",
      type: :object,
      properties: @properties,
      required: @required
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "SantaDeviceResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SantaDevice.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SantaDeviceListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.SantaDevice.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
