defmodule PortalAPI.Schemas.IntunePostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "IntunePostureProvider",
      description: "Microsoft Intune posture provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["intune"]},
        name: %Schema{type: :string},
        tenant_id: %Schema{type: :string},
        is_verified: %Schema{type: :boolean},
        is_disabled: %Schema{type: :boolean},
        disabled_reason: %Schema{type: :string, nullable: true},
        synced_at: %Schema{type: :string, format: :"date-time", nullable: true},
        errored_at: %Schema{type: :string, format: :"date-time", nullable: true},
        error_message: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :account_id, :type, :name, :tenant_id, :is_verified, :is_disabled]
    }))
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "IntunePostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.IntunePostureProvider.Schema}
    }))
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(PortalAPI.Schemas.Object.with_required(%{
      title: "IntunePostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: PortalAPI.Schemas.IntunePostureProvider.Schema
        },
        metadata: PaginationMetadata
      }
    }))
  end
end
