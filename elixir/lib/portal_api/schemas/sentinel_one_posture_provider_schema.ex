defmodule PortalAPI.Schemas.SentinelOnePostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "SentinelOnePostureProvider",
      description: "SentinelOne posture provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["sentinelone"]},
        name: %Schema{type: :string},
        management_url: %Schema{type: :string, format: :uri},
        is_verified: %Schema{type: :boolean},
        is_disabled: %Schema{type: :boolean},
        disabled_reason: %Schema{type: :string, nullable: true},
        synced_at: %Schema{type: :string, format: :"date-time", nullable: true},
        errored_at: %Schema{type: :string, format: :"date-time", nullable: true},
        error_message: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
    }))
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "SentinelOnePostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SentinelOnePostureProvider.Schema}
    }))
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "SentinelOnePostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: PortalAPI.Schemas.SentinelOnePostureProvider.Schema
        },
        metadata: PaginationMetadata
      }
    }))
  end
end
