defmodule PortalAPI.Schemas.OktaAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "OktaAuthProvider",
      description: "Okta Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Provider ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{example: "Okta", type: :string, description: "Provider name"},
        issuer: %Schema{example: "https://example.okta.com", type: :string, description: "Issuer"},
        context: %Schema{
          type: :string,
          description: "Context",
          enum: ["clients_and_portal", "clients_only", "portal_only"]
        },
        client_session_lifetime_secs: %Schema{
          type: :integer,
          description: "Client session lifetime in seconds"
        },
        portal_session_lifetime_secs: %Schema{
          type: :integer,
          description: "Portal session lifetime in seconds"
        },
        is_disabled: %Schema{type: :boolean, description: "Whether provider is disabled"},
        is_default: %Schema{type: :boolean, description: "Whether provider is default"},
        client_id: %Schema{example: "my-client-id", type: :string, description: "Client ID"},
        okta_domain: %Schema{example: "example.okta.com", type: :string, description: "Okta domain"},
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
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.OktaAuthProvider

    OpenApiSpex.schema(%{
      title: "OktaAuthProviderResponse",
      description: "Response schema for single Okta Auth Provider",
      type: :object,
      properties: %{
        data: OktaAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.OktaAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "OktaAuthProviderListResponse",
      description: "Response schema for multiple Okta Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Okta Auth Provider details",
          type: :array,
          items: OktaAuthProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
