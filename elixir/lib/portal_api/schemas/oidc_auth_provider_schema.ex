defmodule PortalAPI.Schemas.OIDCAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder,
             for: Portal.OIDC.AuthProvider, internal: [:is_legacy, :is_verified]}
    OpenApiSpex.schema(%{
      title: "OIDCAuthProvider",
      description: "OIDC Auth Provider",
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
        name: %Schema{example: "OIDC Provider", type: :string, description: "Provider name"},
        issuer: %Schema{example: "https://idp.example.com", type: :string, description: "Issuer"},
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
        client_id: %Schema{example: "my-client-id", type: :string, description: "Client ID"},
        discovery_document_uri: %Schema{
          example: "https://idp.example.com/.well-known/openid-configuration",
          type: :string,
          description: "Discovery document URI"
        },
        email_verification_method: %Schema{
          example: "claim",
          type: :string,
          description: "How sign-in verifies the email claim",
          enum: ["none", "claim", "proof"]
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
        :client_id,
        :client_session_lifetime_secs,
        :context,
        :discovery_document_uri,
        :email_verification_method,
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
    alias PortalAPI.Schemas.OIDCAuthProvider

    OpenApiSpex.schema(%{
      title: "OIDCAuthProviderResponse",
      description: "Response schema for single OIDC Auth Provider",
      type: :object,
      properties: %{
        data: OIDCAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.OIDCAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "OIDCAuthProviderListResponse",
      description: "Response schema for multiple OIDC Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "OIDC Auth Provider details",
          type: :array,
          items: OIDCAuthProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
