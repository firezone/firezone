defmodule PortalAPI.Schemas.EntraAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.Entra.AuthProvider, internal: [:is_verified]}
    OpenApiSpex.schema(%{
      title: "EntraAuthProvider",
      description: "Entra Auth Provider",
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
        name: %Schema{example: "Entra", type: :string, description: "Provider name"},
        issuer: %Schema{
          example: "https://login.microsoftonline.com/tenant-id/v2.0",
          type: :string,
          description: "Issuer"
        },
        context: %Schema{
          example: "clients_and_portal",
          type: :string,
          description: "Context",
          enum: ["clients_and_portal", "clients_only", "portal_only"]
        },
        client_session_lifetime_secs: %Schema{
          example: 604_800,
          type: :integer,
          nullable: true,
          description:
            "Client session lifetime in seconds. Null when the account default applies."
        },
        portal_session_lifetime_secs: %Schema{
          example: 28_800,
          type: :integer,
          nullable: true,
          description:
            "Portal session lifetime in seconds. Null when the account default applies."
        },
        email_claim: %Schema{
          example: "upn",
          type: :string,
          description: "OIDC claim to use as email",
          enum: ["email", "upn", "preferred_username"]
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description: "Whether provider is disabled"
        },
        is_default: %Schema{
          example: false,
          type: :boolean,
          description: "Whether provider is default"
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
      required: [
        :account_id,
        :client_session_lifetime_secs,
        :context,
        :email_claim,
        :id,
        :inserted_at,
        :is_default,
        :is_disabled,
        :issuer,
        :name,
        :portal_session_lifetime_secs,
        :updated_at
      ]
    })
  end

  defmodule Response do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EntraAuthProvider

    OpenApiSpex.schema(%{
      title: "EntraAuthProviderResponse",
      description: "Response schema for single Entra Auth Provider",
      type: :object,
      properties: %{
        data: EntraAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EntraAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "EntraAuthProviderListResponse",
      description: "Response schema for multiple Entra Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Entra Auth Provider details",
          type: :array,
          items: EntraAuthProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
