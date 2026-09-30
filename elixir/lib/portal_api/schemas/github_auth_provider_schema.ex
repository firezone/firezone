defmodule PortalAPI.Schemas.GitHubAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    require OpenApiSpex
    alias OpenApiSpex.Schema

    @derive {PortalAPI.JSON.Encoder, for: Portal.GitHub.AuthProvider, internal: [:is_verified]}
    OpenApiSpex.schema(%{
      title: "GitHubAuthProvider",
      description: "GitHub Auth Provider",
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
        name: %Schema{example: "GitHub", type: :string, description: "Provider name"},
        issuer: %Schema{
          example: "https://github.com/login/oauth",
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
        email_verification_method: %Schema{
          example: "proof",
          type: :string,
          description:
            "How a GitHub identity is first linked to an existing user by email: proof emails a one-time code first, none links on a GitHub-verified email",
          enum: ["none", "proof"]
        },
        is_disabled: %Schema{
          example: false,
          type: :boolean,
          description: "Whether provider is disabled"
        },
        is_default: %Schema{
          example: true,
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
    alias PortalAPI.Schemas.GitHubAuthProvider

    OpenApiSpex.schema(%{
      title: "GitHubAuthProviderResponse",
      description: "Response schema for single GitHub Auth Provider",
      type: :object,
      properties: %{
        data: GitHubAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.GitHubAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "GitHubAuthProviderListResponse",
      description: "Response schema for multiple GitHub Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "GitHub Auth Provider details",
          type: :array,
          items: GitHubAuthProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
