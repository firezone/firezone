defmodule PortalAPI.Schemas.EmailOTPAuthProvider do
  alias OpenApiSpex.Schema

  defmodule Schema do
    use PortalAPI.Schemas.Object

    object(%{
      title: "EmailOTPAuthProvider",
      description: "Email OTP Auth Provider",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid, description: "Provider ID"},
        account_id: %Schema{type: :string, format: :uuid, description: "Account ID"},
        name: %Schema{example: "Email OTP", type: :string, description: "Provider name"},
        issuer: %Schema{example: "firezone", type: :string, description: "Issuer"},
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
    alias PortalAPI.Schemas.EmailOTPAuthProvider

    OpenApiSpex.schema(%{
      title: "EmailOTPAuthProviderResponse",
      description: "Response schema for single Email OTP Auth Provider",
      type: :object,
      properties: %{
        data: EmailOTPAuthProvider.Schema
      }
    })
  end

  defmodule ListResponse do
    require OpenApiSpex
    alias OpenApiSpex.Schema
    alias PortalAPI.Schemas.EmailOTPAuthProvider
    alias PortalAPI.Schemas.PaginationMetadata

    OpenApiSpex.schema(%{
      title: "EmailOTPAuthProviderListResponse",
      description: "Response schema for multiple Email OTP Auth Providers",
      type: :object,
      properties: %{
        data: %Schema{
          description: "Email OTP Auth Provider details",
          type: :array,
          items: EmailOTPAuthProvider.Schema
        },
        metadata: PaginationMetadata
      }
    })
  end
end
