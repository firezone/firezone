defmodule PortalAPI.Schemas.EntraAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "EntraAuthProvider",
      description: "Entra Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Provider ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{example: "Entra", type: :string, description: "Provider name"},
        issuer: %Schema{example: "https://login.microsoftonline.com/tenant-id/v2.0", type: :string, description: "Issuer"},
        context: %Schema{
          type: :string,
          description: "Context",
          enum: ["clients_and_portal", "clients_only", "portal_only"]
        },
        client_session_lifetime_secs: %Schema{
          type: :integer,
          nullable: true,
          minimum: 3_600,
          maximum: 7_776_000,
          description: "Client session lifetime in seconds"
        },
        portal_session_lifetime_secs: %Schema{
          type: :integer,
          nullable: true,
          minimum: 300,
          maximum: 86_400,
          description: "Portal session lifetime in seconds"
        },
        email_claim: %Schema{
          type: :string,
          description: "OIDC claim to use as email",
          enum: ["email", "upn", "preferred_username"]
        },
        is_disabled: %Schema{type: :boolean, description: "Whether provider is disabled"},
        is_default: %Schema{type: :boolean, description: "Whether provider is default"},
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "Creation timestamp"
        },
        updated_at: %Schema{type: :string, format: :"date-time", description: "Update timestamp"}
      }
    })
  end

  defmodule Response do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.EntraAuthProvider

    object(%{
      title: "EntraAuthProviderResponse",
      description: "Response schema for single Entra Auth Provider",
      type: :object,
      properties: %{
        data: EntraAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    use PortalAPI.Schemas.Object
    alias PortalAPI.Schemas.EntraAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    object(%{
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
