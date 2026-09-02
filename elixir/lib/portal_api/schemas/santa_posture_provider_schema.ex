defmodule PortalAPI.Schemas.SantaPostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "SantaPostureProvider",
      description: "Santa posture provider backed by North Pole Security Workshop",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["santa"]},
        name: %Schema{type: :string},
        api_url: %Schema{type: :string, format: :uri},
        is_verified: %Schema{type: :boolean},
        is_disabled: %Schema{type: :boolean},
        disabled_reason: %Schema{type: :string, nullable: true},
        synced_at: %Schema{type: :string, format: :"date-time", nullable: true},
        errored_at: %Schema{type: :string, format: :"date-time", nullable: true},
        error_message: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :account_id,
        :type,
        :name,
        :api_url,
        :is_verified,
        :is_disabled
      ]
    })
  end

  defmodule Response do
    use PortalAPI.Schemas.Object

    object(%{
      title: "SantaPostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SantaPostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.PaginationMetadata

    object(%{
      title: "SantaPostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: PortalAPI.Schemas.SantaPostureProvider.Schema},
        metadata: PaginationMetadata
      }
    })
  end
end
