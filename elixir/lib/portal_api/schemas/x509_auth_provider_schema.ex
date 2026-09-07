defmodule PortalAPI.Schemas.X509AuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.X509.AuthProvider}
    OpenApiSpex.schema(%{
      title: "X509AuthProvider",
      description: "X.509 Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{
          example: "42a7f82f-831a-4a9d-8f17-c66c2bb6e205",
          type: :string,
          format: :uuid,
          description: "Provider ID"
        },
        account_id: %Schema{
          example: "5e6f7d8c-9b0a-1c2d-3e4f-5a6b7c8d9e0f",
          type: :string,
          format: :uuid,
          description: "Account ID"
        },
        name: %Schema{example: "X.509", type: :string, description: "Provider name"},
        context: %Schema{
          example: "clients_only",
          type: :string,
          description: "Context",
          enum: ["clients_only"]
        },
        is_disabled: %Schema{
          example: true,
          type: :boolean,
          description: "Whether provider is disabled"
        },
        inserted_at: %Schema{
          example: "2025-01-01T00:00:00Z",
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{
          example: "2025-01-15T10:30:00Z",
          type: :string,
          format: :"date-time",
          description: "Update timestamp"
        }
      },
      required: [:account_id, :context, :id, :inserted_at, :is_disabled, :name, :updated_at]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias PortalAPI.Schemas.X509AuthProvider

    OpenApiSpex.schema(%{
      title: "X509AuthProviderResponse",
      description: "Response schema for a single X.509 Auth Provider",
      type: :object,
      properties: %{data: X509AuthProvider.Schema}
    })
  end
end
