defmodule PortalAPI.Schemas.DefenderPostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.Defender.PostureProvider}
    OpenApiSpex.schema(%{
      title: "DefenderPostureProvider",
      description: "Microsoft Defender for Endpoint posture provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        account_id: %Schema{type: :string, format: :uuid},
        type: %Schema{type: :string, enum: ["defender"]},
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
      required: [
        :account_id,
        :disabled_reason,
        :error_message,
        :errored_at,
        :id,
        :inserted_at,
        :is_disabled,
        :is_verified,
        :name,
        :synced_at,
        :tenant_id,
        :type,
        :updated_at
      ]
    })

    def map(%Portal.Defender.PostureProvider{posture_provider: %{name: name}}, _map), do: %{type: "defender", name: name}
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    OpenApiSpex.schema(%{
      title: "DefenderPostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.DefenderPostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "DefenderPostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: PortalAPI.Schemas.DefenderPostureProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
