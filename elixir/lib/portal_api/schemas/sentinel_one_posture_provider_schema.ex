defmodule PortalAPI.Schemas.SentinelOnePostureProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.SentinelOne.PostureProvider}
    OpenApiSpex.schema(%{
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
      required: [
        :account_id,
        :disabled_reason,
        :error_message,
        :errored_at,
        :id,
        :inserted_at,
        :is_disabled,
        :is_verified,
        :management_url,
        :name,
        :synced_at,
        :type,
        :updated_at
      ]
    })

    def map(%Portal.SentinelOne.PostureProvider{posture_provider: %{name: name}}, _map), do: %{type: "sentinelone", name: name}

    # Struct fields deliberately withheld from the API.
    def internal do
      [
        :error_email_count
      ]
    end
  end

  defmodule Response do
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SentinelOnePostureProviderResponse",
      type: :object,
      properties: %{data: PortalAPI.Schemas.SentinelOnePostureProvider.Schema}
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "SentinelOnePostureProviderListResponse",
      type: :object,
      properties: %{
        data: %Schema{
          type: :array,
          items: PortalAPI.Schemas.SentinelOnePostureProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
